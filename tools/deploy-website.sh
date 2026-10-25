#!/usr/bin/env bash
# tools/deploy-website.sh: publish the site and the docs under the site's S3 prefix.
#
#   bash tools/deploy-website.sh          checks, then a dry run of the upload
#   bash tools/deploy-website.sh --check  checks only (builds the docs; no AWS needed)
#   bash tools/deploy-website.sh --go     checks, dry-run summary, upload, CloudFront invalidation
#
# What it publishes: website/ at s3://$SITE_BUCKET/halogen/ and the mkdocs docs
# (mkdocs build --strict, so mkdocs must be on PATH) at halogen/docs/. Both are
# assembled into ONE staged tree and synced once, so a site deploy can never
# delete the docs: the sync sees them. A stage without docs/index.html and the
# search index is refused before any AWS call.
#
# Also at the root: llms.txt (copied from the repo) and sitemap.xml (site pages
# plus the docs' pages).
#
# The site workflow (.github/workflows/site.yml) runs --go on every push to
# main that touches the site or the docs. It needs SITE_BUCKET and
# SITE_DISTRIBUTION in the environment; it only ever writes under
# s3://$SITE_BUCKET/halogen/ (sync --delete is scoped to that prefix).
set -euo pipefail

PREFIX="halogen"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/website"
MODE="${1:-dry}"

[ -f "$SRC/index.html" ] || { echo "no site at $SRC" >&2; exit 1; }
[ ! -e "$SRC/docs" ] || { echo "website/docs would collide with the built docs" >&2; exit 1; }

# Public text rules the docs follow too: no em-dash or en-dash, and no
# request to another host at runtime (plain links to our own pages only).
# These are checks on the site's own files, not on the built docs.
fail=0
pages=("$SRC"/*.html "$SRC"/*.css)
if grep -n -e "$(printf '\342\200\224')" -e "$(printf '\342\200\223')" "${pages[@]}"; then
  echo "FAIL: em-dash or en-dash in the site" >&2; fail=1
fi
ext=$(grep -n -o -E '(src|href)="https?://[^"]+"|url\(["'\'']?https?://[^)]+' "${pages[@]}" \
  | grep -v -E 'href="https://(github\.com/peonist-ai/halogen-flash-server|discord\.gg/bcm6QknaV6|peonist\.ai/)' || true)
if [ -n "$ext" ]; then
  echo "$ext"; echo "FAIL: a link or asset on another host" >&2; fail=1
fi
[ "$fail" = 0 ] || exit 1
echo "checks: OK"

# One staged tree: the site, then the docs built into docs/.
command -v mkdocs >/dev/null || { echo "mkdocs not found (pip install -r docs/requirements.txt)" >&2; exit 1; }
STAGE="$(mktemp -d)"
LOG="$STAGE.log"
trap 'rm -rf "$STAGE" "$LOG"' EXIT
cp -R "$SRC/." "$STAGE/"
find "$STAGE" -name SOURCES.md -o -name '.*' -not -path "$STAGE" | xargs rm -rf
mkdocs build --strict -q -f "$ROOT/mkdocs.yml" -d "$STAGE/docs"
# llms.txt at the site root, and a root sitemap: the three site pages, then
# every page the docs build lists.
cp "$ROOT/llms.txt" "$STAGE/llms.txt"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
  for u in https://peonist.ai/halogen/ https://peonist.ai/halogen/benchmarks.html https://peonist.ai/halogen/models.html; do
    echo "<url><loc>$u</loc></url>"
  done
  grep -o '<loc>[^<]*</loc>' "$STAGE/docs/sitemap.xml" | sed 's#^\(.*\)$#<url>\1</url>#' > "$STAGE/.docs-locs"
  cat "$STAGE/.docs-locs"
  echo '</urlset>'
} > "$STAGE/sitemap.xml"
[ -s "$STAGE/.docs-locs" ] || { echo "FAIL: the docs sitemap has no locs" >&2; exit 1; }
rm -f "$STAGE/.docs-locs"
# Not published: the docs' pip pin, and the gzipped sitemap (the CLI would
# label it text/xml with no gzip encoding; sitemap.xml is the one we list).
rm -f "$STAGE/docs/requirements.txt" "$STAGE/docs/sitemap.xml.gz"

# The structural guard: a deploy with no docs in it is refused, so it can
# never be the deploy that deletes them.
for f in index.html docs/index.html docs/search/search_index.json; do
  [ -s "$STAGE/$f" ] || { echo "FAIL: staged tree has no $f; refusing" >&2; exit 1; }
done

# Every link from the site into docs/ must resolve in the build, fragment included.
bad=0
for page in "$SRC"/*.html; do
  while IFS= read -r href; do
    path="${href#docs/}"; frag=""
    case "$path" in *'#'*) frag="${path#*#}"; path="${path%%#*}";; esac
    case "$path" in ""|*/) target="$STAGE/docs/${path}index.html";; *) target="$STAGE/docs/$path";; esac
    if [ ! -f "$target" ]; then
      echo "FAIL: $(basename "$page"): $href has no page in the docs build" >&2; bad=1
    elif [ -n "$frag" ] && ! grep -q -F "id=\"$frag\"" "$target"; then
      echo "FAIL: $(basename "$page"): $href has no #$frag in the docs build" >&2; bad=1
    fi
  done < <(grep -o -E 'href="docs/[^"]*"' "$page" | sed -e 's/^href="//' -e 's/"$//')
done
[ "$bad" = 0 ] || exit 1
echo "docs links from the site: OK"

# Upload passes: NAME|DELETE|CACHE|CONTENT-TYPE|FILTERS, in aws's order (the
# last matching filter wins; x: exclude, i: include; "*" matches across "/").
# Every staged file must fall in exactly one pass. Only the fingerprinted
# Material assets run without --delete (a page cached for 5 minutes may still
# name the previous hash), so the catch-all pass excludes them.
B='i:docs/assets/stylesheets/*.min.css i:docs/assets/stylesheets/*.min.css.map i:docs/assets/javascripts/bundle.*.min.js i:docs/assets/javascripts/bundle.*.min.js.map i:docs/assets/javascripts/workers/*.min.js i:docs/assets/javascripts/workers/*.min.js.map'
C='i:docs/search/search_index.json i:docs/sitemap.xml i:sitemap.xml'
L='i:llms.txt'
PASSES=(
  # HTML: short cache, so an edit shows within minutes even before invalidation.
  "html|1|public, max-age=300|text/html; charset=utf-8|x:* i:*.html"
  "hashed|0|public, max-age=31536000, immutable||x:* $B"
  "index|1|public, max-age=300||x:* $C"
  "llms|1|public, max-age=300|text/plain; charset=utf-8|x:* $L"
  # Fonts get an explicit type (the CLI's guess for .ttf varies by platform).
  "fonts|0|public, max-age=86400|font/ttf|x:* i:*.ttf"
  # Everything else (css, images, the font licence): one day.
  "rest|1|public, max-age=86400||x:*.html x:*.ttf ${B//i:/x:} ${C//i:/x:} ${L//i:/x:}"
)

# Would pass filters FILTERS transfer key KEY? (the include-by-default rule)
passes_key() {
  local st=i f
  set -f; for f in $2; do [[ "$1" == ${f#?:} ]] && st="${f%%:*}"; done; set +f
  [ "$st" = i ]
}
declare -a counts; n=0; selfbad=0
for ((i = 0; i < ${#PASSES[@]}; i++)); do counts[i]=0; done
while IFS= read -r key; do
  hits=0
  for ((i = 0; i < ${#PASSES[@]}; i++)); do
    IFS='|' read -r _ _ _ _ filters <<<"${PASSES[i]}"
    if passes_key "$key" "$filters"; then hits=$((hits + 1)); counts[i]=$((counts[i] + 1)); fi
  done
  n=$((n + 1))
  [ "$hits" = 1 ] || { echo "FAIL: $key is in $hits upload passes" >&2; selfbad=1; }
done < <(cd "$STAGE" && find . -type f | sed 's#^\./##' | sort)
for ((i = 0; i < ${#PASSES[@]}; i++)); do echo "class ${PASSES[i]%%|*}: ${counts[i]}"; done
[ "$selfbad" = 0 ] || exit 1
echo "staged files: $n, each in exactly one class"
[ "$MODE" = "--check" ] && exit 0

: "${SITE_BUCKET:?set SITE_BUCKET}"
: "${SITE_DISTRIBUTION:?set SITE_DISTRIBUTION}"
command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }

DEST="s3://$SITE_BUCKET/$PREFIX/"

# run_passes [--dryrun]: one sync per class, output kept in $LOG.
run_passes() {
  local p name del cache ctype filters args f
  : > "$LOG"
  for p in "${PASSES[@]}"; do
    IFS='|' read -r name del cache ctype filters <<<"$p"
    args=()
    set -f
    for f in $filters; do
      if [ "${f%%:*}" = x ]; then args+=(--exclude "${f#?:}"); else args+=(--include "${f#?:}"); fi
    done
    set +f
    [ "$del" = 1 ] && args+=(--delete)
    [ -n "$ctype" ] && args+=(--content-type "$ctype")
    aws s3 sync "$STAGE/" "$DEST" "$@" "${args[@]}" --cache-control "$cache" | tee -a "$LOG"
  done
}
summary() {
  echo "dry run: $(grep -c 'upload:' "$LOG" || true) uploads, $(grep -c 'delete:' "$LOG" || true) deletes," \
    "$(grep 'delete:' "$LOG" | grep -c "/$PREFIX/docs/" || true) deletes under $PREFIX/docs/"
}

run_passes --dryrun
summary
if [ "$MODE" = "--go" ]; then
  run_passes
  aws cloudfront create-invalidation --distribution-id "$SITE_DISTRIBUTION" \
    --paths "/$PREFIX" "/$PREFIX/*" --query 'Invalidation.Id' --output text
  echo "uploaded to $DEST; invalidation sent"
else
  echo "dry run only; --go uploads"
fi
