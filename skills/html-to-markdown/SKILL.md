---
name: html-to-markdown
description: Convert saved HTML into clean, AI-ready markdown with YAML metadata (title, author, date, description, site). Use this whenever you have HTML in hand — a .html file, a curl/wget dump, a page body captured by a browser tool, a saved DOM snapshot — and need it as markdown for reading, summarizing, indexing, RAG, or feeding to a model. Use it even when the request sounds casual ("clean this page up", "strip the nav out of this", "get the article text from this file", "make this page readable", "turn this dump into markdown"), and use it before hand-rolling any BeautifulSoup, readability, turndown, markdownify, pandoc, or markitdown pipeline of your own — the tool choice here is benchmark-backed and the obvious alternatives measurably lose. This skill converts HTML you already have; it does not fetch URLs.
---

# HTML to AI-ready markdown

Turn HTML into markdown that costs the fewest tokens for the most content, with
metadata attached. The pipeline and its defaults come from a benchmark of 11
converters over 9 pages (`references/benchmark.md`) — the shortcuts people
usually reach for lose by wide, measured margins.

## Use the bundled script

```bash
bash scripts/ensure-deps.sh          # first run only; installs into ~/.cache
node scripts/convert.mjs page.html --url https://example.com/the-page
```

The `--url` is optional but worth passing whenever you know it: it resolves
relative links and materially improves metadata recovery.

Options:

| flag | effect |
| --- | --- |
| `--url <url>` | source URL — better metadata, absolute links |
| `--json` | emit `{markdown, metadata, diagnostics}` instead of a markdown document |
| `--no-frontmatter` | markdown body only |
| `--mode article\|forum\|raw` | override the automatic choice (rarely needed) |
| `-o <path>` | write to a file rather than stdout |

Input can be `-` to read HTML from stdin, so it composes with whatever produced
the HTML.

Default output is a YAML frontmatter block followed by the markdown body. Use
`--json` when you're consuming the result programmatically and want the
diagnostics as data rather than parsing stderr.

## Why this pipeline, and when to deviate

The script picks between two strategies automatically. Understanding the reason
matters, because the automatic choice is a heuristic and you may be able to see
that it guessed wrong.

**Articles, blog posts, docs, news, wikis → extract, then convert.** Defuddle
selects the content element, turndown+gfm writes the markdown. Boilerplate
removal is the single highest-leverage step: tools that find the article first
spend about 1.3× the article's own token count, while tools that convert the
whole DOM spend 3.5–17× for identical content. That is up to a 12× bill for the
same information.

**Forums, Q&A, comment threads → skip extraction entirely.** Every extractor
tested collapses here, because they all assume one article per page: on a Stack
Overflow thread trafilatura scored 0.04 and readability 0.16, keeping the
question and discarding every answer. The script detects these by host and by
repeated answer containers, then converts each post body on its own — scoping to
the posts rather than the whole region drops vote widgets, tag rails and
sidebars, which cut one Stack Overflow thread by 42% with no loss of answers. If
you can see that a page is a discussion and the script called it an article,
pass `--mode forum`.

**Don't substitute trafilatura when code or tables matter.** It has the best
metadata of anything tested and it's the fastest and leanest — genuinely
attractive for news and prose at scale. But it keeps only 18 of 98 code blocks
and 1 of 19 tables, and it flattens multi-line code into a single run-on line
when the code sits inside a list item. That's reproducible across its config
options, so it can't be tuned away. It's a reasonable choice for a bulk news
corpus and a bad one for anything technical.

**Don't reach for markitdown for web pages.** It's an excellent
office-document converter (PDF, DOCX, XLSX) and its popularity gets it
recommended for this task constantly, but on HTML it does no boilerplate
removal, surfaces only a title, and costs 3.5× the tokens.

## Read the diagnostics before trusting the output

The script writes flags to stderr and exits `3` when the input HTML has no
usable article. This exists because the most common failure in practice isn't
bad conversion — it's converting HTML that never contained the content:

- `LIKELY_JS_RENDERED` — a large HTML payload yielding almost no prose. The page
  builds itself with JavaScript, so the content was never in these bytes.
- `LIKELY_BLOCKED` — reads like a captcha, login, or anti-bot wall.
- `NO_ARTICLE` — under 50 words survived.
- `EMBEDDED_CONTENT` — the DOM is empty *but* the file ships a JSON payload
  (Markdoc, Next.js, Nuxt, a bootstrap-state blob) that probably holds the text.

None of these are fixable by converting differently, so don't retry with other
flags or another library.

What to do next depends on whether `EMBEDDED_CONTENT` is also flagged, and the
distinction matters more than it looks:

**Without it**, the content genuinely isn't in these bytes. Report that and get
the page re-fetched with a real browser — headless Chrome, Playwright, or a
browser-automation MCP.

**With it**, the text is in this very file, just not as DOM. Never tell the user
the content is unavailable — it isn't, and that report sends them off to re-fetch
something they already have. Look at the payload and judge whether recovering it
is worth the effort:

- When it maps cleanly onto prose — a single body field holding HTML or markdown,
  the usual shape for blogs and CMS-backed sites — just mine it and convert.
- When it's a nested AST with conditional or variant nodes, recovering it means
  resolving which variant is "the" content, and that's an editorial decision the
  user should make. A Stripe quickstart keeps its whole guide as a Markdoc AST in
  `window.__INITIAL_STATE__`, but as 144 conditional step variants — mining it
  means choosing. Say what you found, what it would take, and let them choose.

Either way, say which route you took and why.

**If you mine a payload, verify provenance before handing it over.** Check that
every code block and every quoted claim in your output appears verbatim in the
source file, and say that you checked. This matters because the failure mode
here isn't an obvious error — it's a fluent, well-organised document assembled
from variants that never coexisted, which reads as authoritative and is wrong in
ways the user cannot see. If something doesn't trace back to the file, drop it
rather than smoothing over the gap.

`FORUM_HOST` is informational, not a problem — it explains why forum mode was
chosen.

## Handing the result on

When the markdown is destined for a model rather than a human reader, keep the
frontmatter. Title, author, date and site are what let a model cite, date, and
disambiguate the source later, and they cost roughly twenty tokens. Reserve
`--no-frontmatter` for cases where the caller has its own metadata handling.

For many pages, loop over them and keep each result in its own file rather than
concatenating — a single merged document loses the per-document metadata that
makes the corpus searchable.

## If the script won't run

It needs Node and, on first use, `scripts/ensure-deps.sh` to install four
packages into `~/.cache/html-to-markdown-skill`. If npm isn't available and
can't be made available, say so rather than silently falling back to a weaker
library — the fallbacks that are usually already installed (markdownify,
pandoc, plain turndown) are precisely the ones the benchmark shows losing by the
largest margins, and quietly producing 8× the tokens is worse than reporting
that a dependency is missing.

`references/benchmark.md` has the full results table and method if you need to
justify a choice or re-run the comparison.
