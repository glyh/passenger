---
name: html-to-markdown
description: |
  Use when you have HTML in hand and need clean, AI-ready markdown with YAML
  metadata (title, author, date, description, site) — a .html file, a curl/wget
  dump, a page body captured by a browser tool, a saved DOM snapshot — for
  reading, summarising, indexing, RAG, or feeding to a model. Triggers include
  casual phrasings: "clean this page up", "strip the nav out of this", "get the
  article text from this file", "make this page readable", "turn this dump into
  markdown". Use it before hand-rolling any BeautifulSoup, readability,
  turndown, markdownify, pandoc, or markitdown pipeline — that choice is
  benchmark-backed and the obvious alternatives measurably lose.
  Does NOT fetch URLs: it converts HTML you already have. To obtain the HTML
  from a live site, especially one needing a login or rendering, use
  `using-passenger`.
---

# HTML to AI-ready markdown

Convert HTML into markdown that costs the fewest tokens for the most content,
with metadata attached. The pipeline and its defaults come from a benchmark of
11 converters over 9 pages (`references/benchmark.md`). The shortcuts people
usually reach for lose by wide, measured margins.

## Run the bundled script

```bash
bash scripts/ensure-deps.sh          # first run only; installs into ~/.cache
node scripts/convert.mjs page.html --url https://example.com/the-page
```

`--url` is optional but worth passing whenever you know it: it resolves relative
links and materially improves metadata recovery.

| Flag | Effect |
| --- | --- |
| `--url <url>` | source URL — better metadata, absolute links |
| `--json` | emit `{markdown, metadata, diagnostics}` instead of a markdown document |
| `--no-frontmatter` | markdown body only |
| `--mode article\|forum\|raw` | override the automatic choice (rarely needed) |
| `-o <path>` | write to a file rather than stdout |

Input can be `-` to read HTML from stdin, so it composes with whatever produced
the HTML.

Default output is a YAML frontmatter block followed by the markdown body. Use
`--json` when consuming the result programmatically and you want diagnostics as
data rather than parsed off stderr.

## Why this pipeline, and when to deviate

The script picks between two strategies automatically. The reason matters,
because the choice is a heuristic and you may be able to see that it guessed
wrong.

**Articles, blog posts, docs, news, wikis → extract, then convert.** Defuddle
selects the content element; turndown+gfm writes the markdown. Boilerplate
removal is the highest-leverage step: tools that find the article first spend
about 1.3× the article's own token count, while whole-DOM converters spend
3.5–17× for identical content — up to a 12× bill for the same information.

**Forums, Q&A, comment threads → skip extraction entirely.** Every extractor
tested collapses here, because they all assume one article per page: on a Stack
Overflow thread trafilatura scored 0.04 and readability 0.16, keeping the
question and discarding every answer. The script detects these by host and by
repeated answer containers, then converts each post body on its own. Scoping to
posts rather than the whole region drops vote widgets, tag rails, and sidebars,
cutting one Stack Overflow thread by 42% with no loss of answers.

**If you can see the page is a discussion and the script called it an article,
pass `--mode forum`.**

**Do not substitute trafilatura when code or tables matter.** It has the best
metadata of anything tested and is the fastest and leanest — genuinely
attractive for news and prose at scale. But it keeps only 18 of 98 code blocks
and 1 of 19 tables, and flattens multi-line code into a single run-on line when
the code sits inside a list item. Reproducible across its config options, so it
cannot be tuned away. Reasonable for a bulk news corpus; bad for anything
technical.

**Do not reach for markitdown for web pages.** It is an excellent
office-document converter (PDF, DOCX, XLSX) and its popularity gets it
recommended for this task constantly, but on HTML it does no boilerplate
removal, surfaces only a title, and costs 3.5× the tokens.

## Read the diagnostics before trusting the output

The script writes flags to stderr and **exits `3` when the input HTML has no
usable article.** This exists because the most common failure in practice is not
bad conversion — it is converting HTML that never contained the content.

| Flag | Meaning |
| --- | --- |
| `LIKELY_JS_RENDERED` | large HTML payload yielding almost no prose. The page builds itself with JavaScript; the content was never in these bytes |
| `LIKELY_BLOCKED` | reads like a captcha, login, or anti-bot wall |
| `NO_ARTICLE` | under 50 words survived |
| `EMBEDDED_CONTENT` | the DOM is empty *but* the file ships a JSON payload (Markdoc, Next.js, Nuxt, a bootstrap-state blob) that probably holds the text |
| `FORUM_HOST` | informational, not a problem — explains why forum mode was chosen |

**None of these are fixable by converting differently.** Do not retry with other
flags or another library.

What to do next depends on whether `EMBEDDED_CONTENT` is also flagged, and the
distinction matters more than it looks.

**Without it**, the content genuinely is not in these bytes. Report that and get
the page re-fetched with a real browser — headless Chrome, Playwright, or a
browser-automation MCP.

`LIKELY_BLOCKED` in particular is not a fetching problem at all: a wall wants a
*logged-in* browser and often a human, which is what the `using-passenger` skill
provides if installed. It renders the page in a real Chrome and hands a human
the window when a site puts up a captcha or a login; then you have HTML worth
converting. **Re-fetching a wall with another plain HTTP client just returns the
wall.**

**With it**, the text is in this very file, just not as DOM. **Never tell the
user the content is unavailable** — it is not, and that report sends them off to
re-fetch something they already have. Look at the payload and judge whether
recovering it is worth the effort:

- **Maps cleanly onto prose** — a single body field holding HTML or markdown,
  the usual shape for blogs and CMS-backed sites — mine it and convert.
- **A nested AST with conditional or variant nodes** — recovering it means
  resolving which variant is "the" content, which is an editorial decision the
  user should make. A Stripe quickstart keeps its whole guide as a Markdoc AST
  in `window.__INITIAL_STATE__`, but as 144 conditional step variants. Say what
  you found, what it would take, and let them choose.

Either way, say which route you took and why.

**If you mine a payload, verify provenance before handing it over.** Check that
every code block and every quoted claim in your output appears verbatim in the
source file, and say that you checked. The failure mode here is not an obvious
error — it is a fluent, well-organised document assembled from variants that
never coexisted, which reads as authoritative and is wrong in ways the user
cannot see. **If something does not trace back to the file, drop it rather than
smoothing over the gap.**

## Handing the result on

When the markdown is destined for a model rather than a human reader, **keep the
frontmatter.** Title, author, date, and site are what let a model cite, date,
and disambiguate the source later, at a cost of roughly twenty tokens. Reserve
`--no-frontmatter` for callers with their own metadata handling.

For many pages, loop and keep each result in its own file rather than
concatenating. A single merged document loses the per-document metadata that
makes the corpus searchable.

## This skill converts; it does not fetch

Worth stating plainly, because it is still what people try: hand it HTML. It has
no network step, and adding one to your invocation is where both failure modes
above come from — a JavaScript-drawn page and a wall both look like valid HTML
to `curl`.

If you got the bytes from a browser tool, **prefer the page's rendered HTML**
(`Page.content()` in Playwright terms) over the original response body. That is
the copy with the JavaScript-drawn content actually in it, and it is what keeps
`LIKELY_JS_RENDERED` from firing.

If the browser you used can convert in the page instead — `using-passenger`
ships a `markdown.js` that walks the live DOM — weigh the two. That one sees
what was rendered and keeps only what is visible; this one removes boilerplate,
recovers metadata, and handles forum threads. **Neither is a superset.**

## If the script will not run

It needs Node and, on first use, `scripts/ensure-deps.sh` to install four
packages into `~/.cache/html-to-markdown-skill`.

**If npm is unavailable and cannot be made available, say so rather than
silently falling back to a weaker library.** The fallbacks usually already
installed (markdownify, pandoc, plain turndown) are precisely the ones the
benchmark shows losing by the largest margins, and quietly producing 8× the
tokens is worse than reporting a missing dependency.

`references/benchmark.md` has the full results table and method if you need to
justify a choice or re-run the comparison.
