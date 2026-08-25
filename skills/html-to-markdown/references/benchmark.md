# Benchmark behind this skill's defaults

Run August 2026. 11 converters (plus this skill's pipeline), 9 pages, every tool
fed **byte-identical HTML** from disk so the comparison measures conversion
rather than crawling. Harness: `/home/lyh/pullground/markdown-conv-bench`.

## Method

Ground truth per page is the real main-content container, pinned by a
hand-checked CSS selector.

| metric | meaning |
| --- | --- |
| recall | fraction of the real article's sentences that survived |
| precision | character-weighted share of output that is article rather than page chrome |
| structure | code blocks / tables / headings / links kept vs. present in source |
| metadata | of title, author, date, description, site — how many recovered and correct |
| bloat | output tokens ÷ tokens of the true article (1.0 = paid for exactly the content) |
| dead | pages where the tool returned essentially nothing (recall < 0.25) |

Composite = 30% recall + 25% precision + 25% structure + 20% metadata. Tokens
counted with `o200k_base`.

Corpus: Wikipedia, Python docs, MDN, Stripe docs, a personal blog, a GitHub repo
page, a Substack post, a BBC news article, a Stack Overflow thread.

## Results

```
 #  tool                        score   recall  prec  struct  meta   tokens  bloat  dead
 1  THIS SKILL                  0.760   0.749  0.703  0.782  0.82    13,276   1.5x    0
 2  defuddle + turndown-gfm     0.746   0.719  0.720  0.744  0.82     9,739   1.4x    1
 3  defuddle                    0.731   0.678  0.702  0.752  0.82     9,556   1.3x    1
 4  trafilatura                 0.684   0.614  0.716  0.571  0.89     8,396   1.2x    1
 5  readability + turndown      0.672   0.673  0.709  0.567  0.76    10,684   1.5x    2
 6  markitdown                  0.649   0.789  0.551  0.936  0.20    21,449   3.5x    0
 7  turndown                    0.614   0.817  0.567  0.908  0.00    22,112   3.5x    0
 8  node-html-markdown          0.610   0.821  0.545  0.909  0.00    22,226   3.5x    0
 9  html-to-markdown (py)       0.606   0.773  0.563  0.934  0.00    37,731   9.3x    0
10  pandoc                      0.592   0.781  0.620  0.812  0.00    38,335   8.0x    0
11  markdownify                 0.549   0.784  0.319  0.936  0.00    70,098  17.2x    0
12  dom-to-semantic-markdown    0.543   0.716  0.443  0.871  0.00    21,549   2.8x    0
13  readability + markdownify   0.438   0.409  0.639  0.462  0.20     7,402   0.9x    4
```

This skill's higher token count than plain defuddle+turndown is deliberate: it
keeps whole forum threads instead of discarding the answers, which is what takes
its dead-page count to zero.

## The four findings that set the defaults

**Extraction is the whole game.** Two clean clusters: find-the-article-first
tools spend 1.2–1.5× the article's tokens, whole-DOM converters spend 3.5–17×.
markdownify emitted 155 KB of markdown for a 4 KB BBC story.

**trafilatura has the best metadata and destroys code.** Title/date/site on 9 of
9 pages, leanest and fastest. But 18 of 98 code blocks and 1 of 19 tables
survive, and code inside a list item gets flattened into one run-on line.
Reproduced across four config variants — not a tuning error.

**Every extractor collapses on Q&A pages.** Stack Overflow thread: trafilatura
0.04, readability 0.16, defuddle 0.32 — while whole-page pandoc scored 0.84.
They find the question and drop the answers. Hence this skill's forum mode.

**On JS-rendered pages the converter is never the problem.** Statically fetched
Stripe docs: best tool salvaged 1.7 KB of nav. Same URL via a real browser:
31 KB of content. Stack Overflow returned HTTP 403 to curl and loaded normally
in Chrome. Hence the diagnostics and the non-zero exit code.

*Correction from eval iteration 1:* "no article" was too strong for the Stripe
case. No DOM-based converter can reach that page's content, which is what the
benchmark measured — but the guide is present in the saved bytes, as a 357 KB
Markdoc AST inside `window.__INITIAL_STATE__`. An agent that walked the AST
recovered the full guide and all 31 code samples from the same static file.
Hence the `EMBEDDED_CONTENT` diagnostic: "not in the DOM" and "not in the file"
are different claims and only the first one was measured.

## Not measured

Jina Reader (`r.jina.ai` returns 401 without an API key) and Firecrawl (key
required). Both hosted, so they would score their crawler as much as their
converter.

## Caveats

Nine pages separates clusters, not adjacent ranks. Ground-truth selectors are
hand-picked. Composite weights are a judgement call — drop the metadata weight
and the raw converters close much of the gap.

## Effect of forum mode

Per-page F1 on the Stack Overflow thread, the page that sinks every extractor:

```
  trafilatura            0.04
  readability+turndown   0.16
  defuddle               0.30
  defuddle+turndown      0.32
  pandoc (whole page)    0.84
  THIS SKILL             0.80   <- forum mode, extraction skipped
```
