// Measuring the pictures on a page, which is the one thing this tool can see
// and the caller structurally cannot.
//
// `fetch` hands over text. When a page's content lives in a photograph -- a
// price list on a menu board, a 图文 note, an infographic -- the markdown is
// not truncated and does not look wrong; it looks like a short page. Ticket
// 015 found that a page deferring content usually *says so* in the text we
// hand over, so the caller can notice for itself. A photograph says nothing.
//
// Same file convention as `walker.js`: one JavaScript expression, an arrow
// function, called by `page.evaluate` with the argument array `pictures.py`
// passes. The threshold stays on the Python side so a reader finds it there
// and a test can vary it without touching this file. It stays JavaScript for
// walker.js's reason as well -- geometry *is* layout, so this cannot be
// computed off a snapshot, and it crosses to a C# port unchanged.
([bigEnough]) => {
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
    // rather than *rendered*, and `fetch` never scrolls -- measured, it took
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
