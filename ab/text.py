"""Pure text measurement, in its own module so both the models and the
extractors can use one ruler without importing each other.
"""
import icu

# Root, not a guessed locale. ICU selects dictionary-based breaking from the
# script of the text itself, so Chinese, Japanese, Thai, Khmer and Lao are
# segmented properly without anyone having to detect the language first.
_LOCALE = icu.Locale.getRoot()


def count_words(text: str) -> int:
    """How many words are here, for text in any script.

    This used to be `len(text.split())`. The scripts that do not put spaces
    between words -- Chinese, Japanese, Thai -- therefore counted a whole
    paragraph as one or two, and every decision made from the number was wrong
    in the direction of believing the page empty: `classify` called a fully
    rendered xiaohongshu search page blocked, and `choose` compared noise to
    noise and returned the extraction that had thrown the content away.
    A 1,800-character note measured 172.

    A BreakIterator is not reusable across calls -- it carries the text it was
    given -- so one is built per call rather than cached.
    """
    breaker = icu.BreakIterator.createWordInstance(_LOCALE)
    breaker.setText(text)
    # Every boundary carries a rule status describing the segment ending
    # there. The NONE band (0 to NONE_LIMIT) is whitespace and punctuation;
    # every band above it -- letters, numbers, ideographs, kana -- is a word.
    return sum(1 for _ in breaker
               if breaker.getRuleStatus() >= icu.UWordBreak.NONE_LIMIT)
