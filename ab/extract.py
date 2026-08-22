"""HTML -> markdown. Browser-agnostic, and the layer least likely to rot."""
import trafilatura


def to_markdown(html: str, url: str = "") -> str:
    out = trafilatura.extract(
        html, url=url or None, output_format="markdown",
        include_links=True, include_tables=True, favor_recall=True,
    )
    return (out or "").strip()
