#!/usr/bin/env python3
"""The site's numbers come from one file, website/release.json.

website/*.html are templates: {{version}}, {{patch_notes}}, {{fig:ID}},
{{val:ID}}, {{unit:ID}}, {{bar:ID:SCALE}} and {{at:PREFIX}} are filled from
release.json. Every figure there names the docs page and heading it comes
from, and `check` fails if the built docs do not hold that value in that
section, so a number on the site cannot drift from the docs.

  site_release.py render SRC_DIR OUT_DIR
      Render SRC_DIR/*.html with SRC_DIR/release.json into OUT_DIR.
  site_release.py check RELEASE_JSON DOCS_BUILD_DIR CHANGELOG_MD
      release.json's version is the changelog's newest, and every figure's
      value is in its docs section.

A release updates release.json (version, release_date, patch_notes, and each
figure it re-measured) in the same public commit as CHANGELOG.md and
docs/performance.md. tools/deploy-website.sh runs both commands.
"""
import html
import json
import re
import sys
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from html.parser import HTMLParser
from pathlib import Path

VER = re.compile(r"^\d+\.\d+\.\d+$")
FIG_ID = re.compile(r"^[a-z0-9_-]+(\.[a-z0-9_-]+)*$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
PLACEHOLDER = re.compile(r"\{\{\s*([a-z_]+)(?::([^}]*))?\s*\}\}")
FIG_KINDS = ("fig", "val", "unit", "bar")


def vkey(v):
    return tuple(int(p) for p in v.split("."))


def num(s):
    try:
        return Decimal(s.replace(",", ""))
    except InvalidOperation:
        return None


def decimals(s):
    return len(s.split(".")[1]) if "." in s else 0


def validate(data):
    """Return the schema errors of a loaded release.json."""
    errs = []
    if not isinstance(data, dict):
        return ["release.json: not an object"]
    ver = data.get("version")
    if not isinstance(ver, str) or not VER.match(ver):
        errs.append("release.json: version must be N.N.N")
        ver = None
    d = data.get("release_date")
    if not isinstance(d, str) or not DATE.match(d):
        errs.append("release.json: release_date must be YYYY-MM-DD")
    notes = data.get("patch_notes")
    if not isinstance(notes, list) or not notes:
        errs.append("release.json: patch_notes must be a non-empty list")
        notes = []
    prev = None
    for i, n in enumerate(notes):
        nv = n.get("version") if isinstance(n, dict) else None
        if not isinstance(nv, str) or not VER.match(nv):
            errs.append(f"release.json: patch_notes[{i}].version must be N.N.N")
            continue
        if not isinstance(n.get("text"), str) or not n["text"].strip():
            errs.append(f"release.json: patch_notes[{i}].text must be non-empty")
        if i == 0 and ver and nv != ver:
            errs.append(f"release.json: patch_notes[0].version {nv} is not version {ver}")
        if prev and vkey(nv) >= vkey(prev):
            errs.append(f"release.json: patch_notes[{i}].version {nv} does not descend from {prev}")
        prev = nv
    figs = data.get("figures")
    if not isinstance(figs, dict) or not figs:
        errs.append("release.json: figures must be a non-empty object")
        figs = {}
    for fid, f in figs.items():
        p = f"release.json: figure {fid}"
        if not FIG_ID.match(fid):
            errs.append(f"{p}: bad id")
        if not isinstance(f, dict):
            errs.append(f"{p}: not an object")
            continue
        if not isinstance(f.get("value"), str) or not f["value"]:
            errs.append(f"{p}: value must be a non-empty string")
        if not isinstance(f.get("unit"), str):
            errs.append(f"{p}: unit must be a string")
        for k in ("label", "conditions"):
            if not isinstance(f.get(k), str) or not f[k].strip():
                errs.append(f"{p}: {k} must be non-empty text")
        m = f.get("measured_at")
        if not isinstance(m, str) or not VER.match(m):
            errs.append(f"{p}: measured_at must be N.N.N")
        elif ver and vkey(m) > vkey(ver):
            errs.append(f"{p}: measured_at {m} is newer than version {ver}")
        s = f.get("source")
        if not isinstance(s, dict) or not isinstance(s.get("page"), str) \
                or not isinstance(s.get("anchor"), str) or not s["anchor"]:
            errs.append(f"{p}: source needs a page and a non-empty anchor")
        dv = f.get("docs_value")
        if dv is not None:
            v = f.get("value")
            if not isinstance(dv, str) or not dv:
                errs.append(f"{p}: docs_value must be a non-empty string")
            elif isinstance(v, str) and v:
                a, b = num(dv), num(v)
                if a is None or b is None:
                    errs.append(f"{p}: docs_value and value must be numbers")
                else:
                    q = Decimal(1).scaleb(-decimals(v.replace(",", "")))
                    if a.quantize(q, rounding=ROUND_HALF_UP) != b:
                        errs.append(f"{p}: docs_value {dv} does not round to value {v}")
    return errs


def load(path):
    text = Path(path).read_text(encoding="utf-8")
    errs = [] if text.endswith("\n") else [f"{path}: no trailing newline"]
    try:
        data = json.loads(text)
    except ValueError as e:
        return None, [f"{path}: {e}"]
    return data, errs + validate(data)


def join_versions(vs):
    vs = sorted(set(vs), key=vkey)
    return vs[0] if len(vs) == 1 else ", ".join(vs[:-1]) + " and " + vs[-1]


def fig_text(f):
    u = f["unit"]
    if u == "":
        return f["value"]
    return f["value"] + (u if u.startswith("%") else " " + u)


def render_text(text, data, name, used, errs):
    figs = data["figures"]

    def sub(m):
        kind, arg = m.group(1), (m.group(2) or "").strip()
        line = text.count("\n", 0, m.start()) + 1
        where = f"{name}:{line}: {{{{{m.group(0)[2:-2].strip()}}}}}"
        if kind == "version":
            return html.escape(data["version"], quote=False)
        if kind == "patch_notes":
            return "\n".join(
                "<li><h3>%s</h3><p>%s</p></li>"
                % (html.escape(n["version"], quote=False), html.escape(n["text"], quote=False))
                for n in data["patch_notes"])
        if kind == "at":
            vs = [f["measured_at"] for k, f in figs.items() if k == arg or k.startswith(arg + ".")]
            if not vs:
                errs.append(f"{where}: no figure matches prefix {arg}")
                return ""
            return html.escape(join_versions(vs), quote=False)
        if kind not in FIG_KINDS:
            errs.append(f"{where}: unknown placeholder kind {kind}")
            return ""
        scale = None
        if kind == "bar":
            arg, _, scale = arg.rpartition(":")
        if arg not in figs:
            errs.append(f"{where}: unknown figure {arg}")
            return ""
        used.add(arg)
        f = figs[arg]
        if kind == "fig":
            s = fig_text(f)
        elif kind == "val":
            s = f["value"]
        elif kind == "unit":
            s = f["unit"]
        else:
            v, sc = num(f["value"]), num(scale or "")
            if v is None or sc is None or sc == 0:
                errs.append(f"{where}: bar needs a numeric value and a scale, got value "
                            f"{f['value']} scale {scale!r}")
                return ""
            s = str((v / sc * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP)) + "%"
        return html.escape(s, quote=False)

    out = PLACEHOLDER.sub(sub, text)
    # Only an opening pair marks a placeholder; the pages' inline JSON and
    # scripts end objects with "}}" already.
    for i, ln in enumerate(out.split("\n"), 1):
        if "{{" in ln:
            errs.append(f"{name}:{i}: an unrendered {{{{ is left: {ln.strip()[:60]}")
    return out


def cmd_render(src, out):
    src, out = Path(src), Path(out)
    data, errs = load(src / "release.json")
    if errs:
        return fail(errs)
    used, rendered = set(), {}
    for p in sorted(src.glob("*.html")):
        rendered[p.name] = render_text(p.read_text(encoding="utf-8"), data, p.name, used, errs)
    for fid in data["figures"]:
        if fid not in used:
            errs.append(f"release.json: figure {fid} is on no page")
    if errs:
        return fail(errs)
    out.mkdir(parents=True, exist_ok=True)
    for name, text in rendered.items():
        (out / name).write_text(text, encoding="utf-8")
    print(f"rendered {len(rendered)} pages from release.json {data['version']}: "
          f"{len(data['figures'])} figures")
    return 0


class Sections(HTMLParser):
    """Collect text chunks, heading starts (level, id, chunk index) and the first </article>."""
    BLOCK = {"p", "li", "ul", "ol", "tr", "td", "th", "table", "div", "br", "pre", "dt", "dd",
             "section", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"}

    def __init__(self):
        super().__init__()
        self.chunks, self.heads, self.article_end, self.skip = [], [], None, 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        if tag in self.BLOCK:
            self.chunks.append(" ")
        if re.fullmatch(r"h[1-6]", tag):
            self.heads.append((int(tag[1]), dict(attrs).get("id"), len(self.chunks)))

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip = max(0, self.skip - 1)
        if tag in self.BLOCK:
            self.chunks.append(" ")
        if tag == "article" and self.article_end is None:
            self.article_end = len(self.chunks)

    def handle_data(self, data):
        if not self.skip:
            self.chunks.append(data)

    def section(self, anchor):
        for i, (lvl, hid, pos) in enumerate(self.heads):
            if hid != anchor:
                continue
            end = len(self.chunks)
            if self.article_end is not None and self.article_end >= pos:
                end = self.article_end
            for lv2, _, p2 in self.heads[i + 1:]:
                if lv2 <= lvl:
                    end = min(end, p2)
                    break
            return re.sub(r"[\s ]+", " ", "".join(self.chunks[pos:end]))
        return None


def cmd_check(rel, docs, changelog):
    data, errs = load(rel)
    if errs:
        return fail(errs)
    docs = Path(docs)
    tops = [vkey(m.group(1)) for m in re.finditer(
        r"^## (\d+\.\d+\.\d+)\s*$", Path(changelog).read_text(encoding="utf-8"), re.M)]
    if not tops:
        errs.append(f"FAIL: no version heading in {changelog}")
    else:
        newest = ".".join(map(str, max(tops)))
        if newest != data["version"]:
            errs.append(f"FAIL: release.json version {data['version']} is not "
                        f"CHANGELOG.md's newest version, {newest}")
    pages = {}
    for fid, f in data["figures"].items():
        page, anchor = f["source"]["page"], f["source"]["anchor"]
        path = docs / (page + "index.html" if page == "" or page.endswith("/") else page)
        if not path.is_file():
            errs.append(f"FAIL: figure {fid}: no page {page} in the docs build")
            continue
        if path not in pages:
            p = Sections()
            p.feed(path.read_text(encoding="utf-8"))
            pages[path] = p
        text = pages[path].section(anchor)
        if text is None:
            errs.append(f"FAIL: figure {fid}: no heading #{anchor} in {page}")
            continue
        v = f.get("docs_value", f["value"])
        if not re.search(r"(?<!\d)(?<!\d[.,])" + re.escape(v) + r"(?!\d)(?![.,]\d)", text):
            errs.append(f'FAIL: figure {fid}: value "{v}" is not in {page}#{anchor}')
    if errs:
        return fail(errs)
    print(f"site figures: {len(data['figures'])} found in their docs sections; "
          f"release.json {data['version']} is CHANGELOG.md's newest: OK")
    return 0


def fail(errs):
    for e in errs:
        print(e, file=sys.stderr)
    return 1


def main(argv):
    if len(argv) == 3 and argv[0] == "render":
        return cmd_render(argv[1], argv[2])
    if len(argv) == 4 and argv[0] == "check":
        return cmd_check(argv[1], argv[2], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
