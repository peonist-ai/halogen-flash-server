"""mkdocs hook: give each docs page the one-line blurb llms.txt has for it.

A page with its own `description` front matter keeps it; a page with no
llms.txt line keeps the site description. Stdlib only.
"""
import re
from pathlib import Path

_BLURBS = {}


def on_config(config, **kwargs):
    _BLURBS.clear()
    text = (Path(config["config_file_path"]).parent / "llms.txt").read_text(encoding="utf-8")
    for m in re.finditer(r"\(\S*?docs/([^)\s]+\.md)\):\s*(.+)", text):
        blurb = " ".join(m.group(2).split()).rstrip(".")
        # A sentence for search results: capital first, full stop last.
        _BLURBS[m.group(1)] = blurb[:1].upper() + blurb[1:] + "."
    return config


def on_page_markdown(markdown, page, config, files, **kwargs):
    blurb = _BLURBS.get(page.file.src_uri)
    # Material escapes the value when it renders the tag, so store it raw.
    if blurb and not page.is_homepage and not page.meta.get("description"):
        page.meta["description"] = blurb
    return markdown
