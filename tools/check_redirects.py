#!/usr/bin/env python3
"""Check the redirect stubs, locally (--local SITE OUT) or live (--live SITEMAP)."""
import argparse
import html
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

UA = "halogen-docs-redirect-check/1"
OLD_DEFAULT = "https://peonist-ai.github.io/halogen-flash-server/"


def locs_of(xml):
    return [html.unescape(m.strip()) for m in re.findall(r"<loc>(.*?)</loc>", xml, re.S)]


def parse_stub(text):
    canon = re.search(r'<link rel="canonical" href="([^"]*)"', text)
    meta = re.search(r'http-equiv="refresh" content="0; url=([^"]*)"', text)
    script = re.search(r"<script>(.*?)</script>", text, re.S)
    return (html.unescape(canon.group(1)) if canon else None,
            html.unescape(meta.group(1)) if meta else None,
            script.group(1) if script else None)


def run_node(script, pathname, search, hash_):
    js = ("var rec=[];var location={pathname:%s,search:%s,hash:%s,replace:function(u){rec.push(u)}};"
          % (json.dumps(pathname), json.dumps(search), json.dumps(hash_))
          + script + ";console.log(JSON.stringify(rec));")
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=20)
    if r.returncode:
        return None
    return json.loads(r.stdout.strip() or "[]")


def local(site, out):
    fails = []
    xml = (Path(site) / "sitemap.xml").read_text(encoding="utf-8")
    locs = locs_of(xml)
    if not locs:
        fails.append("no locs")
    base = min(locs, key=len) if locs else ""
    node = shutil.which("node")
    old_prefix = "/halogen-flash-server/"
    for loc in locs:
        rel = loc[len(base):]
        stub = Path(out) / rel / "index.html" if rel else Path(out) / "index.html"
        if not stub.is_file():
            fails.append(f"missing stub {stub}")
            continue
        page = Path(site) / rel / "index.html" if rel else Path(site) / "index.html"
        if not page.is_file():
            fails.append(f"no page in site for {loc}")
        text = stub.read_text(encoding="utf-8")
        canon, meta, script = parse_stub(text)
        if canon != loc:
            fails.append(f"{stub}: canonical {canon}")
        if meta != loc:
            fails.append(f"{stub}: meta refresh {meta}")
        if not script or json.dumps(loc) not in script or "location.hash" not in script:
            fails.append(f"{stub}: script target/hash")
        if node and script:
            res = run_node(script, old_prefix + rel, "?q=1", "#keep")
            if res != [loc + "?q=1#keep"]:
                fails.append(f"{stub}: node got {res}")
    nf = Path(out) / "404.html"
    for name in ("404.html", ".nojekyll"):
        if not (Path(out) / name).is_file():
            fails.append(f"missing {name}")
    if nf.is_file() and node:
        script = parse_stub(nf.read_text(encoding="utf-8"))[2]
        res = run_node(script, old_prefix + "FLAGS/", "", "#x")
        if res != [base + "FLAGS/#x"]:
            fails.append(f"404.html node got {res}")
        res = run_node(script, old_prefix + "404.html", "", "")
        if res != [base]:
            fails.append(f"404.html (self) node got {res}")
    if not node:
        print("note: node not on PATH, script execution skipped")
    for f in fails:
        print("FAIL", f)
    print(f"{len(locs)} stubs checked, {len(fails)} failures")
    return 1 if fails else 0


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last = None
    for _ in range(2):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            last = e
    return 0, str(last)


def live(sitemap, old_base, new_only):
    if re.match(r"https?://", sitemap):
        st, xml = get(sitemap)
        if st != 200:
            print(f"FAIL sitemap {sitemap} -> {st}")
            return 1
    else:
        xml = Path(sitemap).read_text(encoding="utf-8")
    locs = locs_of(xml)
    if not locs:
        print("FAIL no locs")
        return 1
    new_base = min(locs, key=len)
    node = shutil.which("node")
    bad = 0

    def rep(url, st, ok, why=""):
        nonlocal bad
        if not ok:
            bad += 1
        print(f"{st} {'OK' if ok else 'FAIL'} {url} {why}".rstrip())

    for loc in locs:
        st, body = get(loc)
        rep(loc, st, st == 200 and "stylesheets/halogen.css" in body,
            "" if st == 200 and "stylesheets/halogen.css" in body else "(no theme)")
        if new_only:
            continue
        old = old_base + loc[len(new_base):]
        st, body = get(old)
        canon, _, script = parse_stub(body)
        why = f"(canonical {canon})" if canon != loc else ""
        ok = st == 200 and canon == loc
        if ok and node and script:
            res = run_node(script, urlparse(old).path, "", "#frag")
            if res != [loc + "#frag"]:
                ok, why = False, f"(script sends #frag to {res})"
        rep(old, st, ok, why)
    st, body = get(new_base + "search/search_index.json")
    ok = False
    if st == 200:
        try:
            ok = bool(json.loads(body).get("docs"))
        except ValueError:
            pass
    rep(new_base + "search/search_index.json", st, ok)
    if not new_only:
        # GitHub Pages answers an unknown path with 404.html (status 404); its
        # script must still send the reader to the matching new page.
        for rest, want in (("404.html", new_base), ("no-such-page/", new_base + "no-such-page/#x")):
            u = old_base + rest
            st, body = get(u)
            script = parse_stub(body)[2]
            ok, why = st in (200, 404) and json.dumps(new_base) in body, ""
            if ok and node and script:
                res = run_node(script, urlparse(u).path, "", "#x" if rest != "404.html" else "")
                if res != [want]:
                    ok, why = False, f"(script sends to {res})"
            rep(u, st, ok, why)
    print(f"{bad} failures")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--local", nargs=2, metavar=("SITE_DIR", "OUT_DIR"))
    ap.add_argument("--live", metavar="SITEMAP_URL_OR_FILE")
    ap.add_argument("--old-base", default=OLD_DEFAULT)
    ap.add_argument("--new-only", action="store_true")
    a = ap.parse_args()
    if a.local:
        return local(*a.local)
    if a.live:
        ob = a.old_base if a.old_base.endswith("/") else a.old_base + "/"
        return live(a.live, ob, a.new_only)
    ap.error("give --local or --live")


if __name__ == "__main__":
    sys.exit(main())
