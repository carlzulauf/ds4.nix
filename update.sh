#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash cacert curl git jq nix nix-prefetch-github gnused coreutils

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# ds4.nix flake update script
#
# Best-practice patterns (as of mid-2026):
#   • nixpkgs package updateScripts use passthru.updateScript = ./update.sh,
#     with a nix-shell shebang and tools like nix-prefetch-github,
#     update-source-version (common-updater-scripts), or nix-update.
#   • Flake-level update scripts run `nix flake update` to refresh flake.lock,
#     then update any pinned fetchFromGitHub sources via nix-prefetch-github.
#   • Prefer bash scripts over Nix-written updateScripts for maintainability.
#   • Use `set -euo pipefail`, fail fast, and commit with descriptive messages.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Build the flake and refresh the ./result symlink, so `result` always points at
# what the current flake.nix/flake.lock actually produce. Called on every path
# through this script -- including the "already up to date" one, where step 1
# may still have moved nixpkgs. `set -e` means a broken build aborts here,
# before anything gets committed.
build_and_link() {
  echo ""
  echo "=== Build and verify (refreshes ./result) ==="
  nix build .#ds4 --out-link result
  echo "Built: $(readlink result)"
}

echo "=== Step 1: Update flake.lock (nixpkgs, flake-utils) ==="
nix flake update --commit-lock-file 2>&1

echo ""
echo "=== Step 2: Determine latest ds4 upstream commit ==="

OWNER="antirez"
REPO="ds4"

# Fetch the latest commit of the default branch from GitHub API. One request
# gives us both the SHA and its date; we need the date for the version string.
COMMIT_JSON=$(curl -s "https://api.github.com/repos/$OWNER/$REPO/commits/main")

LATEST_SHA=$(echo "$COMMIT_JSON" | jq -r '.sha')

if [[ -z "$LATEST_SHA" || "$LATEST_SHA" == "null" ]]; then
  echo "ERROR: Could not fetch latest commit SHA for $OWNER/$REPO" >&2
  exit 1
fi
echo "Latest upstream commit: $LATEST_SHA"

# nixpkgs `0-unstable-<date>` versions take the date from the commit itself,
# not from whenever the update happened to run, so that a given rev always
# produces the same version string. Normalize to UTC: the API returns an
# ISO-8601 timestamp that may carry a non-zero offset.
LATEST_COMMIT_DATE_RAW=$(echo "$COMMIT_JSON" | jq -r '.commit.committer.date')

if [[ -z "$LATEST_COMMIT_DATE_RAW" || "$LATEST_COMMIT_DATE_RAW" == "null" ]]; then
  echo "ERROR: Could not read commit date for $LATEST_SHA" >&2
  exit 1
fi

LATEST_COMMIT_DATE=$(date -u -d "$LATEST_COMMIT_DATE_RAW" +%Y-%m-%d)
echo "Commit date (UTC):      $LATEST_COMMIT_DATE"

# Read the current pinned rev from flake.nix
CURRENT_REV=$(sed -n 's/.*rev = "\(.*\)".*/\1/p' flake.nix)

echo "Current pinned rev:   $CURRENT_REV"

if [[ "$LATEST_SHA" == "$CURRENT_REV" ]]; then
  echo "ds4 source is already up to date — skipping hash refresh."
  build_and_link
  echo ""
  echo "=== All done ==="
  exit 0
fi

echo ""
echo "=== Step 3: Prefetch new source hash ==="

# nix-prefetch-github outputs JSON with rev, hash (SRI), etc.
PREFETCH_JSON=$(nix-prefetch-github --rev "$LATEST_SHA" "$OWNER" "$REPO")

# Modern nix-prefetch-github emits the SRI hash under `.hash` (there is no
# `.sha256` key), so `jq -r '.sha256'` would silently yield the string "null"
# and write `hash = "null"` into flake.nix, breaking evaluation.
NEW_HASH=$(echo "$PREFETCH_JSON" | jq -r '.hash')
echo "New source hash:      $NEW_HASH"

if [[ -z "$NEW_HASH" || "$NEW_HASH" == "null" || "$NEW_HASH" != sha256-* ]]; then
  echo "ERROR: prefetch returned an invalid hash: '$NEW_HASH'" >&2
  echo "Prefetch output was:" >&2
  echo "$PREFETCH_JSON" >&2
  exit 1
fi

# Extract the current hash from flake.nix (SRI format with sha256- prefix)
CURRENT_HASH=$(sed -n 's/.*hash = "\(.*\)".*/\1/p' flake.nix)

echo ""
echo "=== Step 4: Update flake.nix ==="

# Replace the rev line
sed -i "s|rev = \"$CURRENT_REV\"|rev = \"$LATEST_SHA\"|" flake.nix

# Replace the hash line (preserve the surrounding whitespace and structure)
sed -i "s|hash = \"$CURRENT_HASH\"|hash = \"$NEW_HASH\"|" flake.nix

# Update the version date string to the upstream commit date
sed -i "s|version = \"0-unstable-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\"|version = \"0-unstable-$LATEST_COMMIT_DATE\"|" flake.nix

build_and_link

echo ""
echo "=== Step 5: Commit the update ==="

git add flake.nix flake.lock
git commit -m "ds4: update source to $LATEST_SHA (rev $(echo "$LATEST_SHA" | head -c 7))

Upstream commit $LATEST_SHA fetched from $OWNER/$REPO.

Updated nixpkgs and flake-utils inputs via \`nix flake update\`."

echo ""
echo "=== All done ==="
