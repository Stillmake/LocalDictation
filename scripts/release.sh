#!/bin/zsh

# Releases a notarized DMG through four independent stages:
#
#   publish  GitHub release $SLUG-{version}-{build} on $RELEASE_REPO with the DMG
#   feed     ../releases/$SLUG/version.json from changelog.json, committed and pushed
#   site     dispatches deploy.yml in $SITE_REPO (skipped when empty)
#   cask     ../homebrew-tap/scripts/bump.sh (skipped when the cask is absent)
#
# Every stage is idempotent: re-running one that already happened is a
# no-op, so a failed run is finished by re-running the same command. The
# one ordering rule: feed, site and cask point at the published DMG, so
# they refuse to run until it is up. Version and build come from the DMG.
# Reference: RELEASE.md.
#
# Usage:
#   ./scripts/release.sh [--dmg PATH] [--only STAGES] [--skip STAGES] [--notes FILE]
#
#   --dmg    the DMG to release (default: $APP_NAME.dmg in the project root)
#   --only   comma-separated stages to run (default: all)
#   --skip   comma-separated stages to leave out
#   --notes  release body for publish, when changelog.json has no entry for
#            this DMG yet (the feed stage still needs that entry)

SLUG="localdictation"
APP_NAME="LocalDictation"
SITE_REPO=""
CASK="$SLUG"
RELEASE_REPO="Stillmake/releases"
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RELEASES_DIR="$ROOT_DIR/../releases"
TAP_DIR="$ROOT_DIR/../homebrew-tap"

DMG="$ROOT_DIR/$APP_NAME.dmg"
STAGES=(publish feed site cask)
SKIP=()
NOTES_ARG=""
while (( $# )); do
  case "$1" in
    --dmg) DMG="${2:A}"; shift 2 ;;
    --only) STAGES=(${(s:,:)2}); shift 2 ;;
    --skip) SKIP=(${(s:,:)2}); shift 2 ;;
    --notes) NOTES_ARG="${2:A}"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done
STAGES=(${STAGES:|SKIP})

[[ -f "$DMG" ]] || { echo "Error: no DMG at $DMG"; exit 1; }
ASSET="${DMG:t}"

MOUNT=$(mktemp -d)
NOTES_FILE=$(mktemp)
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null; rmdir "$MOUNT" 2>/dev/null; rm -f "$NOTES_FILE"' EXIT
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet -readonly || { echo "Error: cannot mount $DMG"; exit 1; }
APPS=("$MOUNT"/*.app(N))
(( ${#APPS} == 1 )) || { echo "Error: expected one .app in $DMG"; exit 1; }
PLIST="$APPS[1]/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
hdiutil detach "$MOUNT" -quiet
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "Error: no version info in $PLIST"; exit 1; }

TAG="$SLUG-$VERSION-$BUILD"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
CHANGELOG="$RELEASES_DIR/$SLUG/changelog.json"
echo "$APP_NAME $VERSION ($BUILD) → $TAG [${(j:, :)STAGES}]"

# Prints the changelog entry for this DMG as markdown; fails when the
# newest entry is not it.
entry_markdown() {
  [[ -f "$CHANGELOG" ]] || { echo "Error: no $CHANGELOG" >&2; return 1; }
  bun -e '
    const [entry] = require(process.argv[1]);
    if (`${entry.version} (${entry.build})` !== process.argv[2]) {
      console.error(`Error: changelog.json leads with ${entry.version} (${entry.build}), not ${process.argv[2]}.`);
      process.exit(1);
    }
    console.log(entry.notes.map((n) => `### ${n.title}\n\n${n.items.map((i) => `- ${i}`).join("\n")}`).join("\n\n"));
  ' "$CHANGELOG" "$VERSION ($BUILD)"
}

# The release's DMG digest, empty when the release or asset is missing.
published_sha() {
  gh release view "$TAG" --repo "$RELEASE_REPO" --json assets \
    --jq ".assets[] | select(.name == \"$ASSET\") | .digest" 2>/dev/null | sed 's/^sha256://'
}

stage_publish() {
  local remote
  if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    remote=$(published_sha)
    if [[ "$remote" == "$SHA" ]]; then
      echo "publish: $TAG already holds this DMG."
      return 0
    elif [[ -n "$remote" ]]; then
      echo "Error: $TAG holds a different $ASSET. Bump the build, or delete the release to replace it."
      return 1
    fi
    gh release upload "$TAG" "$DMG" --repo "$RELEASE_REPO" || return 1
    echo "publish: uploaded $ASSET to the existing $TAG."
    return 0
  fi
  if [[ -n "$NOTES_ARG" ]]; then
    cat "$NOTES_ARG" > "$NOTES_FILE"
  else
    entry_markdown > "$NOTES_FILE" || { echo "Add the entry to changelog.json, or pass --notes FILE."; return 1; }
  fi
  printf '\n\nCommit: %s\n' "$(git -C "$ROOT_DIR" rev-parse --short "$VERSION^{commit}" 2>/dev/null || git -C "$ROOT_DIR" rev-parse --short HEAD)" >> "$NOTES_FILE"
  gh release create "$TAG" "$DMG" --repo "$RELEASE_REPO" \
    --title "$APP_NAME $VERSION ($BUILD)" --notes-file "$NOTES_FILE" --target main || return 1
  echo "publish: created $TAG."
}

require_published() {
  [[ "$(published_sha)" == "$SHA" ]] || { echo "Error: $1 needs $TAG published with this DMG; run the publish stage."; return 1; }
}

stage_feed() {
  require_published feed || return 1
  entry_markdown >/dev/null || return 1
  bun "$RELEASES_DIR/scripts/feed.mjs" "$SLUG" "$ASSET" || return 1
  git -C "$RELEASES_DIR" add -- "$SLUG" || return 1
  if git -C "$RELEASES_DIR" diff --cached --quiet -- "$SLUG"; then
    echo "feed: $SLUG is already committed."
  else
    git -C "$RELEASES_DIR" commit -q -m "$SLUG: $VERSION ($BUILD)" -- "$SLUG" || return 1
  fi
  git -C "$RELEASES_DIR" pull -q --rebase --autostash origin main || return 1
  git -C "$RELEASES_DIR" push -q origin HEAD:main || return 1
  echo "feed: live."
}

stage_site() {
  [[ -n "$SITE_REPO" ]] || { echo "site: no site repo, skipped."; return 0; }
  require_published site || return 1
  gh workflow run deploy.yml --repo "$SITE_REPO" --ref main || return 1
  echo "site: deploy dispatched in $SITE_REPO; confirm the run succeeds."
}

stage_cask() {
  [[ -f "$TAP_DIR/Casks/$CASK.rb" ]] || { echo "cask: no Casks/$CASK.rb, skipped."; return 0; }
  require_published cask || return 1
  "$TAP_DIR/scripts/bump.sh" "$CASK" "$DMG"
}

FAILED=()
for stage in $STAGES; do
  if ! "stage_$stage"; then
    FAILED+=$stage
    # Nothing else may point at a DMG that is not up.
    [[ $stage == publish ]] && break
  fi
done

if (( ${#FAILED} )); then
  echo "Failed: ${(j:, :)FAILED}. Fix and re-run: ./scripts/release.sh --only ${(j:,:)FAILED}"
  exit 1
fi
echo "Done: $TAG."
