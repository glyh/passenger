// Keep the footnotes that `markdown.js` would throw away.
//
// Run this in the page *before* `markdown.js`, on the same tab. It hands back
// how many elements it rescued; the markdown comes from the next call.
//
//     var fix = await File.ReadAllTextAsync(".../unstrip-asides.js");
//     var js  = await File.ReadAllTextAsync(".../markdown.js");
//     var rescued = await Page.EvaluateAsync<int>(fix);
//     var markdown = await Page.EvaluateAsync<string>(js);
//
// Why this exists. `markdown.js` strips `aside` as furniture, beside `nav`,
// `header` and `footer`. On a news site or a blog that is right -- an `aside`
// is a pull quote, a related-links rail, a promo box. But **docutils and
// Sphinx emit footnotes as `<aside class="footnote">`**, so on the technical
// documentation this tool is most often pointed at, the prose comes back and
// the footnotes and reference list the prose points *at* silently do not.
// Measured on PEP 8: 45,389 characters against the page's own 45,407. An
// eighteen-character shortfall for losing the entire reference apparatus, so
// the count you were told to read against expectation cannot show it to you.
//
// Why it is a separate file rather than a change to the strip list. The two
// jobs `aside` does are both real, and a strip list is one global answer to a
// question that has two. Narrowing it inside `markdown.js` would trade a silent
// loss on documentation for a silent gain of furniture everywhere else, which
// is the failure ticket 028 and ticket 044 were about; and `markdown.js` is one
// expression that reads in a single pass, which is the property that makes it
// worth reading before you run it. This keeps that file answering "what is the
// content", and puts "this page's markup disagrees about what counts as
// furniture" where you can see it at the call site, on the pages where it is
// true.
//
// What it does. An element is rescued if it is a footnote, endnote, citation
// or bibliography by class or by DPUB-ARIA role, *or if it contains one* --
// the second half matters, because docutils wraps its footnotes in an outer
// `aside.footnote-list` that carries no role, and the walk skips a whole
// subtree at the outermost `aside` it meets. Each one is replaced by a
// `section` holding the same children and the same attributes, so it is no
// longer an `aside` for the strip list to match, and the class survives for
// anyone reading the DOM afterwards.
//
// This mutates the live page, which is fine on a tab you opened to read and is
// worth knowing about on a tab a human is using. It is idempotent: run it
// twice and the second run rescues nothing, because there is no `aside` left.
//
// Where the selectors come from, so they can be checked rather than trusted:
//
//   - docutils RELEASE-NOTES, 0.18: "HTML5: Use the semantic tag <aside> for
//     footnote text and citations, topics (except abstract and toc),
//     admonitions, and system messages. Use <nav> for the Table of Contents."
//     That is the change that made this necessary.
//   - docutils RELEASE-NOTES, 0.19 (2022-07-05): "HTML5: Wrap groups of
//     footnotes in an <aside> for easier styling. The CSS rule
//     .footnote-list { display: contents; } can be used to restore the
//     behaviour of custom CSS styles." That is the outer wrapper, and the
//     reason `wanted()` matches a container as well as a footnote.
//   - Digital Publishing WAI-ARIA 1.0, https://www.w3.org/TR/dpub-aria-1.0/,
//     examples 5 and 24, both of which are literally
//     `<aside id="fn01" role="doc-footnote">`. The role half of KEEP is the
//     standard's own markup. It also draws the distinction KEEP relies on:
//     doc-footnote is an individual note in the body, doc-endnotes a
//     collection at the end of a section.
//   - HTML Standard section 4.3.5: an `aside` is "content that is tangentially
//     related... often represented as sidebars in printed typography", and
//     advertising and groups of `nav` are named uses. So stripping `aside` by
//     default is correct, which is why this is a separate opt-in file and not
//     an edit to that strip list.
//
// Verified on PEP 8 to produce output byte-identical to running `markdown.js`
// with `aside` removed from its strip list -- 46,122 characters, 23 absolute
// links, a populated `## References` -- and to change nothing at all on
// theguardian.com (22 asides, none rescued), numpy's Sphinx pages (one empty
// print-only aside), en.wikipedia.org and blog.rust-lang.org.
//
// It is a recipe, like `markdown.js`. If a site spells its footnotes some
// other way, add it to KEEP and run your copy.
() => {
  const KEEP =
    'aside.footnote, aside.footnote-list, aside.endnote, aside.endnote-list, ' +
    'aside.citation, aside.citation-list, ' +
    '[role=doc-footnote], [role=doc-footnotes], [role=doc-endnote], ' +
    '[role=doc-endnotes], [role=doc-bibliography], [role=doc-biblioentry]';

  // Matched *or* containing a match: the outer wrapper carries no role.
  const wanted = (el) => el.matches(KEEP) || el.querySelector(KEEP) !== null;

  let rescued = 0;
  // Snapshot the list first. Replacing an element while iterating a live
  // collection skips the next one, and nested asides mean there are elements
  // here whose parent this loop is also about to replace -- `isConnected` is
  // not the guard for that (a moved child stays connected), the snapshot is.
  for (const el of [...document.querySelectorAll('aside')]) {
    if (!wanted(el)) continue;
    const section = document.createElement('section');
    for (const attr of el.attributes) section.setAttribute(attr.name, attr.value);
    while (el.firstChild) section.appendChild(el.firstChild);
    el.replaceWith(section);
    rescued++;
  }
  return rescued;
}
