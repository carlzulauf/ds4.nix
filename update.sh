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

echo "=== Step 1: Update flake.lock (nixpkgs, flake-utils) ==="
nix flake update --commit-lock-file 2>&1

echo ""
echo "=== Step 2: Determine latest ds4 upstream commit ==="

OWNER="antirez"
REPO="ds4"

# Fetch the latest commit SHA of the default branch from GitHub API
LATEST_SHA=$(curl -s "https://api.github.com/repos/$OWNER/$REPO/commits/main" \
  | jq -r '.sha')

if [[ -z "$LATEST_SHA" || "$LATEST_SHA" == "null" ]]; then
  echo "ERROR: Could not fetch latest commit SHA for $OWNER/$REPO" >&2
  exit 1
fi
echo "Latest upstream commit: $LATEST_SHA"

# Read the current pinned rev from flake.nix
CURRENT_REV=$(sed -n 's/.*rev = "\(.*\)".*/\1/p' flake.nix)

echo "Current pinned rev:   $CURRENT_REV"

if [[ "$LATEST_SHA" == "$CURRENT_REV" ]]; then
  echo "ds4 source is already up to date — skipping hash refresh."
  echo ""
  echo "=== All done ==="
  exit 0
fi

echo ""
echo "=== Step 3: Prefetch new source hash ==="

# nix-prefetch-github outputs JSON with rev, sha256, etc.
PREFETCH_JSON=$(nix-prefetch-github --rev "$LATEST_SHA" "$OWNER" "$REPO")

NEW_HASH=$(echo "$PREFETCH_JSON" | jq -r '.sha256')
echo "New source hash:      $NEW_HASH"

# Extract the current hash from flake.nix (SRI format with sha256- prefix)
CURRENT_HASH=$(sed -n 's/.*hash = "\(.*\)".*/\1/p' flake.nix)

echo ""
echo "=== Step 4: Update flake.nix ==="

# Replace the rev line
sed -i "s|rev = \"$CURRENT_REV\"|rev = \"$LATEST_SHA\"|" flake.nix

# Replace the hash line (preserve the surrounding whitespace and structure)
sed -i "s|hash = \"$CURRENT_HASH\"|hash = \"$NEW_HASH\"|" flake.nix

# Update the version date string to today
TODAY=$(date +%Y-%m-%d)
sed -i "s|version = \"0-unstable-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\"|version = \"0-unstable-$TODAY\"|" flake.nix

echo ""
echo "=== Step 5: Commit the update ==="

git add flake.nix flake.lock
git commit -m "ds4: update source to $LATEST_SHA (rev $(echo "$LATEST_SHA" | head -c 7))

Upstream commit $LATEST_SHA fetched from $OWNER/$REPO.

Updated nixpkgs and flake-utils inputs via \`nix flake update\`."

echo ""
echo "=== All done ==="
