// Measuring the pictures on a page, which the text cannot carry.
//
// When a page's content lives in a photograph -- a price list on a menu board,
// a 图文 note, an infographic -- what you read back is not truncated and does
// not look wrong. It looks like a short page. Ticket 015 found that a page
// deferring content usually *says so* in the text you were handed, so you can
// notice for yourself. A photograph says nothing.
//
// This used to run on the server, on every reply, and hand you the numbers
// whether you wanted them or not. Ticket 048 moved it here: the tool reports
// nothing it was not asked for, so measuring is yours the same way reading is.
// Nothing will tell you a page was picture-borne. Run this when a page reads
// shorter than it should.
//
// Same shape as walker.js: one arrow function, evaluated in the page. It stays
// JavaScript for walker.js's reason -- geometry *is* layout, so it cannot be
// computed off a snapshot.
//
// Returns { largest, count, src }: the biggest visible picture as a share of
// the viewport, how many clear the threshold, and how to reach the biggest one
// -- a URL where there is one, and a CSS selector where there is not, which
// `Page.Locator(src).ScreenshotAsync()` takes (ticket 014).
//
// Roughly: 0.0 on a docs page, 0.10 on an illustrated article, 0.27 on a
// comic, 0.38 on a three-photo note, 1.92 on apple.com's hero. A small picture
// can still be the whole content -- an xkcd comic measures 0.06 -- which is
// why this is a number and not a verdict.
(args) => {
  // The threshold lives here, the way walker.js holds DEFAULT_STRIP and
  // DEFAULT_ROOTS: it used to be a constant on the C# side passed in on every
  // call, which is where a reader looked for it when the C# side was the only
  // caller. Now you are.
  //
  // Ten percent of the viewport, and measured rather than picked. At 5% the
  // count contradicts the ratio on exactly the pages that matter -- a
  // xiaohongshu explore listing of 30 thumbnails counts 30 while its largest
  // picture is 0.06 of the viewport, and an illustrated wikipedia article
  // counts 5 while its largest is 0.10. At 10% both of those count 0 and a
  // three-photo note still counts 3, so the two numbers corroborate instead of
  // arguing. Pass `[0.05]` if you want to see it argue.
  const [bigEnough = 0.10] = args ?? [];

  // What a picture is, measured rather than assumed. All five tags were
  // chosen against pages where each one was the biggest box on the page:
  // IMG on a xiaohongshu 图文 note, VIDEO on a xiaohongshu video note, svg on
  // an ourworldindata grapher, CANVAS on stripe's blog, IFRAME on APOD --
  // which without IFRAME read 0.00, the Astronomy Picture of the Day with no
  // picture. IFRAME also belongs on the walker's own terms: it is in its
  // OPAQUE set, so an iframe's content is not in the markdown either, which
  // makes it exactly a payload that is not text.
  const PICTURE = "img, video, svg, canvas, iframe";

  const vw = innerWidth, vh = innerHeight, viewport = vw * vh;
  if (!viewport) return { largest: 0, count: 0, src: "" };

  // Where an element is, for the case where it has no URL to point at. An
  // inline svg is markup and a canvas is pixels in memory, so neither has a
  // src -- and those are two of the five tags. A selector is what `script`
  // needs anyway: ticket 014 measured `locator.screenshot()` reaching a
  // picture with no URL at all.
  function path(el) {
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && n !== document.body; n = n.parentElement) {
      const tag = n.tagName.toLowerCase();
      const kin = n.parentElement
        ? [...n.parentElement.children].filter((c) => c.tagName === n.tagName)
        : [n];
      parts.unshift(kin.length > 1 ? `${tag}:nth-of-type(${kin.indexOf(n) + 1})` : tag);
    }
    return parts.length ? "body > " + parts.join(" > ") : "body";
  }

  // A lazy-loading page parks a 1x1 base64 placeholder in `src` and swaps it
  // on scroll, so the URL of apple.com's 2359x1443 hero was
  // `data:image/gif;base64,R0lGOD...` -- true, and useless to fetch. The
  // element is still right there, so point at it instead.
  function reach(el) {
    const url = el.currentSrc || el.src || "";
    return url && !url.startsWith("data:") ? url : path(el);
  }

  let largest = null, largestArea = 0, count = 0;
  for (const el of document.querySelectorAll(PICTURE)) {
    const rect = el.getBoundingClientRect();
    const area = rect.width * rect.height;
    // Visible by the same rule the text walk uses (ticket 035), so the two
    // agree about what is on the page. Position is deliberately not tested:
    // requiring a box to be on screen and topmost measures *above the fold*
    // rather than *rendered*, and nothing here scrolls -- measured, it took
    // apple.com from 30 large pictures to 1 and moonofalabama's photo to 0.
    if (area <= 0 || !el.checkVisibility({ visibilityProperty: true })) continue;
    if (area / viewport >= bigEnough) count += 1;
    if (area > largestArea) { largestArea = area; largest = el; }
  }
  // Four places, not three, so a favicon reads 0.0001 rather than 0.0. At
  // three it rounded to zero while `src` still pointed at it, which is a
  // result that contradicts itself. Suppressing the src below a floor was the
  // alternative, and that is this side ruling on a number it hands over --
  // the thing tickets 005 and 021 removed everywhere else.
  return {
    largest: +(largestArea / viewport).toFixed(4),
    count,
    src: largest ? reach(largest) : "",
  };
}
