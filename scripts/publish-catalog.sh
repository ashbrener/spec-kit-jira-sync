#!/usr/bin/env bash
# =============================================================================
# scripts/publish-catalog.sh — open the spec-kit community-catalog bump PR
# =============================================================================
# The community catalog (github/spec-kit → extensions/catalog.community.json) is
# a static, version-pinned entry; it doesn't watch this repo. After you tag a
# release, run this to open the PR that bumps this extension's catalog entry.
#
# NO SECRET / PAT REQUIRED — it uses your LOCAL `gh` login (the same auth that
# can already push to your fork and open PRs upstream). Run it after `gh release
# create` (or any time): `scripts/publish-catalog.sh v0.3.0`.
#
# ─── COPY-TO-A-SIBLING-EXTENSION CHECKLIST ──────────────────────────────────
#   1. Copy this file.
#   2. Edit the THREE values just below (CATALOG_ID, EXT_REPO, FORK).
#   That's it — no tokens, no secrets. (CI variant needing a PAT:
#   .github/workflows/catalog-publish.yml — optional, for hands-off releases.)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── EDIT THESE THREE WHEN COPYING TO A SIBLING REPO ────────────────────────
CATALOG_ID="${CATALOG_ID:-jira-sync}"                       # catalog entry id (key under `extensions`)
EXT_REPO="${EXT_REPO:-ashbrener/spec-kit-jira-sync}"        # owner/name of THIS extension repo
FORK="${FORK:-ashbrener/spec-kit}"                          # YOUR fork of the catalog repo
# ─── constants ──────────────────────────────────────────────────────────────
UPSTREAM="github/spec-kit"
CATALOG="extensions/catalog.community.json"

command -v gh >/dev/null  || { echo "error: gh (GitHub CLI) is required + authenticated (gh auth login)"; exit 1; }
command -v jq >/dev/null  || { echo "error: jq is required"; exit 1; }

# Tag: arg 1, else the most recent tag in this repo.
TAG="${1:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
[ -n "$TAG" ] || { echo "error: no tag given and none found — usage: $0 vX.Y.Z"; exit 1; }
VER="${TAG#v}"
URL="https://github.com/${EXT_REPO}/archive/refs/tags/${TAG}.zip"
BR="chore/catalog-${CATALOG_ID}-${VER}"

# The installer is ZIP-only — fail early if the tag's tarball isn't published.
code="$(curl -sS -o /dev/null -w '%{http_code}' -L "$URL")"
[ "$code" = "200" ] || { echo "error: tarball not published (HTTP $code) at $URL — push the tag first"; exit 1; }

echo "Publishing ${CATALOG_ID} ${TAG} → ${UPSTREAM} catalog (via your fork ${FORK})"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# Make sure the fork's main matches upstream (we only ever branch off it).
gh repo sync "$FORK" --source "$UPSTREAM" --branch main --force >/dev/null
gh repo clone "$FORK" "$work/fork" -- --depth 1 --branch main >/dev/null 2>&1
cd "$work/fork"

tmp="$(mktemp)"
jq --arg id "$CATALOG_ID" --arg ver "$VER" --arg url "$URL" '
  if (.extensions[$id] | type) != "object"
  then error("catalog has no entry for id \($id) — submit it first")
  else .extensions[$id].version = $ver | .extensions[$id].download_url = $url
  end
' "$CATALOG" > "$tmp"
jq empty "$tmp"            # validate JSON
mv "$tmp" "$CATALOG"

if git diff --quiet -- "$CATALOG"; then
  echo "Catalog already at ${TAG} — nothing to do."; exit 0
fi
git --no-pager diff -- "$CATALOG"

git checkout -b "$BR" >/dev/null
git commit -am "chore(catalog): bump ${CATALOG_ID} to ${TAG}" >/dev/null
git push -u origin "$BR" --force >/dev/null
FORK_OWNER="${FORK%%/*}"
gh pr create --repo "$UPSTREAM" --base main --head "${FORK_OWNER}:${BR}" \
  --title "chore(catalog): bump ${CATALOG_ID} to ${TAG}" \
  --body "Bumps \`extensions.${CATALOG_ID}\` to **${TAG}** (\`version\` ${VER}, \`download_url\` → the tag .zip). JSON re-validated; no other entries touched." \
  || gh pr list --repo "$UPSTREAM" --head "$BR" --json url -q '.[0].url // empty'
