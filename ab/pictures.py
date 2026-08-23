"""How much of this page is a picture.

The one measurement in this project the caller could not have made for itself.
Everything else `fetch` reports is derived from the markdown it hands over --
`char_count` is `len(text)`, and ticket 016 closed unbuilt precisely because
the markers saying content was withheld were already in that text. A
photograph is not in it, was never in it, and no amount of reading the result
reveals that the price list was in the picture.

So this reports, and rules on nothing. `Pictures.largest` is a number, not a
verdict: ticket 005 removed a tier that blocked a page for having fewer words
than a threshold, and ticket 021 removed a mode that picked an extractor by
comparing two word counts. Both were this side ruling on a number it hands
over anyway. The caller has `largest`, `count`, `char_count` and the markdown,
and is better placed than a threshold here to say whether 0.38 on a
1,989-character page means the answer is in the photograph.
"""
from importlib import resources
from typing import Any

from .models import Pictures

# Ten percent of the viewport, and measured rather than picked. At 5% the
# count contradicts the ratio on exactly the pages that matter -- a
# xiaohongshu explore listing of 30 thumbnails counts 30 while its largest
# picture is 0.06 of the viewport, and an illustrated wikipedia article counts
# 5 while its largest is 0.10. At 10% both of those count 0 and a three-photo
# note still counts 3, so the two numbers corroborate instead of arguing.
BIG_ENOUGH = 0.10

# Read once at import, for walker.js's reasons in full (ticket 034): reading
# per call would make which code ran unanswerable, and importing it here means
# a `pictures.js` missing from the wheel fails `pythonImportsCheck` rather
# than the first fetch.
_JS = resources.files("ab").joinpath("pictures.js").read_text(encoding="utf-8")

NOTHING = Pictures(largest=0.0, count=0, src="")


def measure(page: Any) -> Pictures:
    """Shell: what the biggest visible picture on this page is, and where.

    A page that cannot answer -- a wedged renderer (ticket 012), a navigation
    mid-flight -- reports no pictures rather than failing the fetch. That is
    the honest reading of a page nothing could measure, and unlike `dom_text`
    there is no fallback that could quietly stand in for a bug here: an
    exception means zero, and zero is what a page with no pictures returns
    too. The measurement is not load-bearing enough to lose a whole fetch
    over.
    """
    try:
        seen = page.evaluate(_JS, [BIG_ENOUGH])
    except Exception:
        return NOTHING
    return Pictures.model_validate(seen)
