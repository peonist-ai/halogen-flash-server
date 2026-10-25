#!/usr/bin/env python3
"""Write a GitHub Pages tree of redirect stubs, one per page in a built mkdocs site.

usage: docs_redirects.py SITE_DIR OUT_DIR [--old-prefix /halogen-flash-server/]
"""
import argparse
import html
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

STUB = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Moved</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="canonical" href="{href}">
<meta name="robots" content="noindex">
<script>location.replace({js} + location.search + location.hash);</script>
<meta http-equiv="refresh" content="0; url={href}">
</head>
<body>
<p>This page moved to <a href="{href}">{href}</a>.</p>
</body>
</html>
"""

NOTFOUND = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Moved</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<script>
(function () {{
  var oldPrefix = {old};
  var newBase = {new};
  var p = location.pathname;
  var rest = p.indexOf(oldPrefix) === 0 ? p.slice(oldPrefix.length) : "";
  if (rest === "404.html") rest = "";
  location.replace(newBase + rest + location.search + location.hash);
}})();
</script>
<meta http-equiv="refresh" content="0; url={href}">
</head>
<body>
<p>This page moved to <a href="{href}">{href}</a>.</p>
</body>
</html>
"""


def read_locs(site):
    xml = (Path(site) / "sitemap.xml").read_text(encoding="utf-8")
    return [html.unescape(m.strip()) for m in re.findall(r"<loc>(.*?)</loc>", xml, re.S)]


def common_base(locs):
    """site_url: the loc that is a prefix of every other loc (the root page)."""
    root = min(locs, key=len)
    if not root.endswith("/"):
        root += "/"
    return root


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("site")
    ap.add_argument("out")
    ap.add_argument("--old-prefix", default="/halogen-flash-server/")
    a = ap.parse_args()
    locs = read_locs(a.site)
    if not locs:
        print("no locs in sitemap.xml", file=sys.stderr)
        return 1
    base = common_base(locs)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for loc in locs:
        if not loc.startswith(base):
            print(f"loc not under site_url {base}: {loc}", file=sys.stderr)
            return 1
        rel = loc[len(base):]
        dest = out / rel / "index.html" if rel else out / "index.html"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(STUB.format(href=html.escape(loc, quote=True), js=json.dumps(loc)),
                        encoding="utf-8")
        n += 1
    (out / "404.html").write_text(
        NOTFOUND.format(old=json.dumps(a.old_prefix), new=json.dumps(base),
                        href=html.escape(base, quote=True)), encoding="utf-8")
    (out / ".nojekyll").write_text("", encoding="utf-8")
    print(f"{n} stubs written to {out} (new base {base})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
