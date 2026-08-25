#!/usr/bin/env node
/**
 * HTML -> AI-ready markdown + metadata.
 *
 * Pipeline choice is driven by benchmark results (see references/benchmark.md):
 * Defuddle selects the content, turndown+gfm converts it. Forum/Q&A pages skip
 * extraction entirely, because every extractor tested throws the answers away.
 *
 * Usage:
 *   node convert.mjs <file.html|-> [options]
 *
 *   --url <url>        Source URL. Improves metadata and resolves relative links.
 *   --mode <mode>      auto (default) | article | forum | raw
 *   --json             Emit {markdown, metadata, diagnostics} as JSON.
 *   --with-source      With --json, also return the HTML that was converted,
 *                      so tests can assert stage-scoped invariants (everything
 *                      in the selected region must survive into the markdown).
 *   --no-frontmatter   Markdown body only, no YAML header.
 *   -o <path>          Write to a file instead of stdout.
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';

const CACHE = process.env.HTML2MD_CACHE
  || path.join(os.homedir(), '.cache', 'html-to-markdown-skill');

// Bare specifiers must resolve against the cache dir under ESM rules (some deps
// export subpaths only under the "import" condition), so we import through a
// shim that physically lives there. Written on demand so the skill self-heals.
const LOADER_SRC = `export { Defuddle } from 'defuddle/node';
export { JSDOM } from 'jsdom';
export { default as TurndownService } from 'turndown';
export { gfm } from 'turndown-plugin-gfm';
`;
function loadDeps() {
  const loader = path.join(CACHE, 'loader.mjs');
  if (!fs.existsSync(loader)) {
    if (!fs.existsSync(path.join(CACHE, 'node_modules'))) {
      console.error(`error: dependencies missing. Run scripts/ensure-deps.sh first.`);
      process.exit(4);
    }
    fs.writeFileSync(loader, LOADER_SRC);
  }
  return import(pathToFileURL(loader).href);
}

// ---------------------------------------------------------------- args
const argv = process.argv.slice(2);
const opt = { mode: 'auto', frontmatter: true, json: false, withSource: false, url: '', out: '', input: '' };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--url') opt.url = argv[++i];
  else if (a === '--mode') opt.mode = argv[++i];
  else if (a === '--json') opt.json = true;
  else if (a === '--with-source') opt.withSource = true;
  else if (a === '--no-frontmatter') opt.frontmatter = false;
  else if (a === '-o') opt.out = argv[++i];
  else if (a === '-h' || a === '--help') { console.log(fs.readFileSync(new URL(import.meta.url)).toString().split('*/')[0]); process.exit(0); }
  else opt.input = a;
}
if (!opt.input) { console.error('error: no input. Pass a .html file or - for stdin.'); process.exit(2); }

const html = opt.input === '-'
  ? fs.readFileSync(0, 'utf8')
  : fs.readFileSync(opt.input, 'utf8');

// ---------------------------------------------------------------- diagnose
// Cheap signals about whether this HTML is even worth converting. A converter
// cannot repair a fetch that came back as a shell, a captcha, or a login wall,
// so the honest move is to say so rather than emit confident nav junk.
const WALL = [
  'verify you are human', 'checking your browser', 'enable javascript',
  'unusual traffic', 'access denied', 'captcha', 'cf-browser-verification',
  'please enable cookies', 'are you a robot', '请完成验证', 'sign in to continue',
];
const FORUM_HOST = /stackoverflow|stackexchange|superuser|serverfault|askubuntu|reddit\.|discourse|news\.ycombinator|discuss\.|forum\.|\/issues\/|\/discussions\//i;

const JSON_ISLAND = [
  [/\$\$mdtype/, 'Markdoc'],
  [/__NEXT_DATA__|self\.__next_f/, 'Next.js'],
  [/window\.__NUXT__/, 'Nuxt'],
  [/window\.__INITIAL_STATE__|__APOLLO_STATE__|__PRELOADED_STATE__/, 'bootstrap state'],
  [/__remixContext/, 'Remix'],
  [/"@type"\s*:\s*"(?:Article|NewsArticle|TechArticle|BlogPosting)"/, 'schema.org article'],
];

function embeddedPayload(rawHtml) {
  for (const [re, name] of JSON_ISLAND) if (re.test(rawHtml)) return name;
  return null;
}

function diagnose(doc, extractedWords, host, htmlBytes, rawHtml) {
  const flags = [];
  const bodyText = (doc.body?.textContent || '').replace(/\s+/g, ' ').trim();
  const lower = bodyText.slice(0, 4000).toLowerCase();
  const scripts = doc.querySelectorAll('script').length;

  if (WALL.some(w => lower.includes(w)) && bodyText.length < 3000)
    flags.push('LIKELY_BLOCKED: page reads like a captcha, login, or anti-bot wall');

  // A big HTML payload that renders almost no text is a client-rendered shell.
  if (bodyText.length < 1500 && scripts > 5)
    flags.push('LIKELY_JS_RENDERED: lots of script, almost no text in the DOM');
  const mount = doc.querySelector('#root, #__next, #app, [data-reactroot]');
  if (mount && (mount.textContent || '').trim().length < 200)
    flags.push('LIKELY_JS_RENDERED: empty client-side mount point');

  if (extractedWords < 50)
    flags.push('NO_ARTICLE: fewer than 50 words survived extraction');
  // A large HTML payload that yields almost no prose is the signature of a
  // client-rendered shell. Deliberately not a ratio-of-page-text rule: short
  // articles on nav-heavy sites are correct extractions, and warning about
  // those just teaches people to ignore the warnings.
  else if (htmlBytes > 100000 && extractedWords < 500)
    flags.push(`LIKELY_JS_RENDERED: ${Math.round(htmlBytes/1024)}KB of HTML yielded only ${extractedWords} words`);

  if (host && FORUM_HOST.test(host)) flags.push('FORUM_HOST');
  if (flags.some(f => f.startsWith('NO_ARTICLE') || f.startsWith('LIKELY_JS_RENDERED'))) {
    const kind = embeddedPayload(rawHtml);
    if (kind) flags.push(`EMBEDDED_CONTENT: the page ships a ${kind} payload — the text is probably in this file, just not in the DOM`);
  }
  return flags;
}

// ---------------------------------------------------------------- convert
const PRE_CHROME = [
  '.js-copy-button', '[data-nosnippet]', '[aria-hidden="true"]', 'button',
  '.linenos', '.lineno', '.line-numbers', '.gutter', '.copy', '.code-header',
  '.s-btn', 'svg',
].join(', ');

function makeTurndown(TurndownService, gfm) {
  const td = new TurndownService({
    headingStyle: 'atx',
    codeBlockStyle: 'fenced',
    bulletListMarker: '-',
    hr: '---',
  });
  td.use(gfm);
  td.remove(['script', 'style', 'noscript', 'iframe', 'svg', 'form']);
  // Fenced code. Sites inject toolbars into <pre> (copy buttons, "Run", line
  // number gutters); requiring <code> to be pre's first child let any of that
  // disable fencing entirely and leak button text into the code.
  td.addRule('fencedCode', {
    filter: n => n.nodeName === 'PRE',
    replacement: (_c, node) => {
      const pre = node.cloneNode(true);
      pre.querySelectorAll(PRE_CHROME).forEach(x => x.remove());
      const code = pre.querySelector('code') || pre;
      const cls = `${code.className || ''} ${node.className || ''}`;
      const m = cls.match(/(?:language|lang|highlight|brush:)[-\s]([a-z0-9+#]+)/i);
      let lang = m ? m[1].toLowerCase() : '';
      if (['none', 'default', 'plain', 'text'].includes(lang)) lang = '';
      const body = (code.textContent || '').replace(/^\n+/, '').replace(/\s+$/, '');
      if (!body) return '';
      if (!lang) lang = LANG_BY_CODE.get(codeKey(body)) || '';
      // The fence must outlive any backtick run inside the code.
      const longest = (body.match(/`+/g) || []).reduce((a, x) => Math.max(a, x.length), 0);
      const fence = '`'.repeat(Math.max(3, longest + 1));
      return `\n\n${fence}${lang}\n${body}\n${fence}\n\n`;
    },
  });
  // Docs sites wrap table cell content in <p>/<dl>. Turndown then emits rows
  // containing raw newlines, which is not merely ugly - it breaks the markdown
  // table syntax outright, so the reader gets neither a table nor clean prose.
  td.addRule('inlineTableCellBlocks', {
    filter: n => ['P', 'DL', 'DT', 'DD', 'DIV'].includes(n.nodeName) &&
                 typeof n.closest === 'function' && n.closest('td, th'),
    replacement: c => ((c || '').trim() ? c.trim() + ' ' : ''),
  });

  return td;
}

// Per-post body containers, in the markup conventions forums actually use.
const POST_BODY = '.js-post-body, .s-prose, [itemprop="text"], .post-text, ' +
  '.comment-copy, .usertext-body, .post__content, .topic-body .cooked';

const FORUM_ROOTS = ['#mainbar', '#content', 'main', '[role="main"]', 'article', 'body'];
const FORUM_STRIP = 'nav, header, footer, aside, script, style, noscript, form, ' +
  '.sidebar, #sidebar, .advertisement, .ad, [role="navigation"], [role="banner"], ' +
  '[role="complementary"], [aria-hidden="true"]';

function forumRoot(doc) {
  for (const sel of FORUM_ROOTS) {
    const n = doc.querySelector(sel);
    if (n && (n.textContent || '').trim().length > 400) return n;
  }
  return doc.body;
}

function looksLikeForum(doc, host) {
  if (host && FORUM_HOST.test(host)) return true;
  // Repeated answer containers are the structural tell. Each must hold real
  // prose: syntax highlighters class their code-comment spans ".comment", which
  // otherwise makes every documentation page with sample code look like a forum.
  const candidates = doc.querySelectorAll(
    '.answer, [id^="answer-"], .comment, .reply, [itemprop="suggestedAnswer"], ' +
    '[itemprop="acceptedAnswer"], .post-reply, .thread-item'
  );
  let n = 0;
  for (const el of candidates) if ((el.textContent || '').trim().length > 200) n++;
  return n >= 3;
}

function yaml(meta) {
  const esc = v => {
    const s = String(v).replace(/\r?\n/g, ' ').trim();
    return /^[\w][\w .,\/:+-]*$/.test(s) ? s : `"${s.replace(/"/g, '\\"')}"`;
  };
  const lines = ['---'];
  for (const [k, v] of Object.entries(meta)) {
    if (v === null || v === undefined || v === '' ) continue;
    lines.push(`${k}: ${esc(v)}`);
  }
  lines.push('---');
  return lines.join('\n');
}

function tidy(md) {
  return md
    .replace(/\n{3,}/g, '\n\n')            // runs of blank lines
    .replace(/[ \t]+$/gm, '')              // trailing spaces
    .replace(/^(\s*[-*]\s*)$/gm, '')       // empty list bullets left by stripped nodes
    .replace(/!\[\]\(data:[^)]*\)/g, '')   // inline base64 images: pure token burn
    .trim() + '\n';
}

// ---------------------------------------------------------------- main
const { Defuddle, JSDOM, TurndownService, gfm } = await loadDeps();

const dom = new JSDOM(html, opt.url ? { url: opt.url } : {});
const doc = dom.window.document;
let host = '';
try { host = opt.url ? new URL(opt.url).host + new URL(opt.url).pathname : ''; } catch {}

// Defuddle normalises markup before we ever see it, so anything we need must be
// rescued from the original DOM first. Three things, all learned from fixtures:
//   - it deletes anchors classed "reference"/"xref" ALONG WITH their text, which
//     guts Sphinx cross-references mid-sentence;
//   - it folds line-number gutters into the <code> text, where no selector can
//     reach them and they become fake first lines of code;
//   - it strips language classes off <pre>, but preserves them on <code>.
const LANG_BY_CODE = new Map();
const codeKey = t => (t || '').trim().replace(/\s+/g, ' ').slice(0, 200);

const GUTTER = '.linenos, .lineno, .line-numbers, .gutter, .code-line-numbers, ' +
  '.hljs-ln-numbers, td.rouge-gutter';

function sanitize(document) {
  let touched = 0;
  for (const a of document.querySelectorAll('a[class]')) {
    if (/reference|xref/i.test(a.className)) { a.removeAttribute('class'); touched++; }
  }
  for (const g of document.querySelectorAll(GUTTER)) { g.remove(); touched++; }
  for (const pre of document.querySelectorAll('pre')) {
    const code = pre.querySelector('code');
    const cls = `${(code && code.className) || ''} ${pre.className || ''}`;
    const m = cls.match(/(?:language|lang|highlight|brush:)[-\s]([a-z0-9+#]+)/i);
    if (!m) continue;
    const lang = m[1].toLowerCase();
    if (['none', 'default', 'plain', 'text'].includes(lang)) continue;
    LANG_BY_CODE.set(codeKey((code || pre).textContent), lang);
    if (code && !/language-/.test(code.className || '')) {
      code.className = `${code.className || ''} language-${lang}`.trim();
      touched++;
    }
  }
  return touched;
}
const derisked = sanitize(doc);

const safeHtml = derisked ? dom.serialize() : html;

let article = null;
try {
  article = await Defuddle(safeHtml, opt.url || undefined, { markdown: false, url: opt.url || undefined });
} catch (e) {
  article = null;
}

const extractedHtml = article?.content || '';
const extractedWords = extractedHtml.replace(/<[^>]*>/g, ' ').split(/\s+/).filter(Boolean).length;

let mode = opt.mode;
if (mode === 'auto') {
  mode = looksLikeForum(doc, host) ? 'forum' : 'article';
}

const td = makeTurndown(TurndownService, gfm);
let markdown = '';
let convertedHtml = '';
if (mode === 'article' && extractedHtml) {
  convertedHtml = extractedHtml;
  markdown = td.turndown(extractedHtml);
} else if (mode === 'raw') {
  convertedHtml = html;
  markdown = td.turndown(html);
} else {
  // forum, or article-mode fallback when extraction produced nothing.
  // Prefer the individual post bodies: forum pages wrap each post in a known
  // container, and taking those directly drops vote widgets, tag rails and
  // sidebars that converting the whole region would drag in.
  const posts = doc.querySelectorAll(POST_BODY);
  if (mode === 'forum' && posts.length >= 2) {
    const parts = [];
    for (const post of posts) {
      post.querySelectorAll(FORUM_STRIP).forEach(n => n.remove());
      const body = td.turndown(post.innerHTML || '').trim();
      if (body) parts.push(body);
      convertedHtml += post.innerHTML || '';
    }
    markdown = parts.join('\n\n---\n\n');
  } else {
    const root = forumRoot(doc);
    root.querySelectorAll(FORUM_STRIP).forEach(n => n.remove());
    convertedHtml = root.innerHTML || '';
    markdown = td.turndown(convertedHtml);
    if (mode === 'article') mode = 'fallback-full-page';
  }
}
markdown = tidy(markdown);

function trimAuthor(a) {
  if (!a) return null;
  const parts = String(a).split(/\s*,\s*/).filter(Boolean);
  return parts.length > 3 ? parts.slice(0, 3).join(', ') + ', et al.' : parts.join(', ');
}

const metadata = {
  title: article?.title || doc.title || null,
  author: trimAuthor(article?.author),
  published: article?.published || null,
  description: article?.description || null,
  site: article?.site || null,
  url: opt.url || article?.domain || null,
  word_count: markdown.split(/\s+/).filter(Boolean).length,
  extraction: mode,
};
for (const k of Object.keys(metadata)) if (!metadata[k]) delete metadata[k];

const diagnostics = diagnose(doc, mode === 'article' ? extractedWords : metadata.word_count, host, html.length, html);

const out = opt.json
  ? JSON.stringify({ markdown, metadata, diagnostics,
      ...(opt.withSource ? { convertedHtml } : {}) }, null, 2)
  : (opt.frontmatter ? yaml(metadata) + '\n\n' + markdown : markdown);

if (opt.out) fs.writeFileSync(opt.out, out);
else process.stdout.write(out);

for (const f of diagnostics) console.error(`[html-to-markdown] ${f}`);
if (diagnostics.some(f => f.startsWith('LIKELY_JS_RENDERED') || f.startsWith('LIKELY_BLOCKED') || f.startsWith('NO_ARTICLE'))) {
  if (diagnostics.some(f => f.startsWith('EMBEDDED_CONTENT'))) {
    console.error('[html-to-markdown] No article in the DOM, but this file carries an embedded content payload.');
    console.error('[html-to-markdown] Two routes: re-render the page in a real browser, or mine the JSON payload in this file directly. Do not report the content as unavailable without checking the payload.');
  } else {
    console.error('[html-to-markdown] This HTML has no usable article. Re-fetch it with a real browser; no converter can fix an empty fetch.');
  }
  process.exitCode = 3;
}
