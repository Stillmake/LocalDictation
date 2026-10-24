#!/bin/zsh

# Usage:
# ./create-dmg.sh [-s SchemeName] [-v version] [--ascprofile ProfileName]
# -s selects the scheme; without it, SCHEME is used or an application scheme
# is selected automatically/interactively.
# -v sets the marketing version. With it the working tree must be clean; after
# a y/n confirmation (showing the latest tag) every MARKETING_VERSION in
# project.pbxproj is updated and committed as "version: bump to <n>" before the
# rest of the flow runs. Without it the version already in the project is
# shipped as is.
# --ascprofile selects the asc credential profile for notarization, overriding
# ASC_PROFILE from the environment.
# Archives the app signed directly with your Developer ID certificate,
# notarizes, and creates the DMG. No re-sign/export step needed.
#
# ONE-TIME SETUP — create the Developer ID certificate in Xcode (done once):
#   1. You should have added your Apple account: Xcode → Settings → Accounts
#      → "+" → Apple ID (the team "Hangzhou Gongshu District Xiangde Software
#      Development Studio", Team ID 2BLN6SHK5S).
#   2. Select that team → "Manage Certificates…" → "+" → "Developer ID
#      Application". Xcode generates the cert AND installs the private key
#      into your login keychain.
#   3. Requirement for notarization: download/give Notary access to that team,
#      and keep the ASC keys in ~/.asc/config.json (below).
#   No need to run this script from a machine with nothing else set up — the
#   cert created above is what this script's archive step signs with.
#
# Requirements:
# - Xcode logged into your Apple account + the Developer ID certificate above
#   (created once via Manage Certificates — see ONE-TIME SETUP).
# - App Store Connect API key present either in ~/.asc/config.json, in the
#   system keychain (asc auth), or via the environment
#   (ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILE).
# - At startup the script selects the sole available Developer ID signing team,
#   certificate, and asc credential profile automatically. It asks only when
#   there are multiple choices. Set SIGNING_TEAM / SIGNING_IDENTITY /
#   ASC_PROFILE to skip all prompts (fully unattended).
# - ASC_BYPASS_KEYCHAIN=1 is exported automatically when the chosen
#   notarization profile is not stored in the keychain.

set -euo pipefail

# Terminal colors
BOLD=$'\033[1m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

# Prints an error and exits, so the guards below stay one line each.
die() { echo "${RED}Error: $*${RESET}" >&2; exit 1; }

# The scheme is the one name only the author can pick; the product name comes
# from OSX_APP_NAME and differs per configuration, so it is read back below.
PROJECT_PATHS=(*.xcodeproj(N))
[[ "${#PROJECT_PATHS[@]}" -eq 1 ]] || die "expected exactly one .xcodeproj here, found ${#PROJECT_PATHS[@]}."
PROJECT_PATH="${PROJECT_PATHS[1]}"

# Parse release options. Command-line values override their environment values.
VERSION=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -s|-v|--ascprofile)
      option="$1"
      [[ "$#" -ge 2 && -n "$2" ]] || die "$option requires a value."
      case "$option" in
        -s) SCHEME="$2" ;;
        -v) VERSION="$2" ;;
        --ascprofile) ASC_PROFILE="$2" ;;
      esac
      shift 2
      ;;
    -s?*) SCHEME="${1#-s}"; shift ;;
    -v?*) VERSION="${1#-v}"; shift ;;
    --ascprofile=*)
      ASC_PROFILE="${1#--ascprofile=}"
      [[ -n "$ASC_PROFILE" ]] || die "--ascprofile requires a value."
      shift
      ;;
    --) shift; break ;;
    -*) die "unknown option $1." ;;
    *) die "unexpected argument '$1'. Use -s, -v, or --ascprofile." ;;
  esac
done
[[ "$#" -eq 0 ]] || die "unexpected argument '$1'. Use -s, -v, or --ascprofile."

# Bumping requires a clean tree, edits project.pbxproj (both configurations
# carry MARKETING_VERSION) and commits just that file, so the release always
# corresponds to one version commit. A y/n confirmation showing the latest tag guards the commit.
if [[ -n "$VERSION" ]]; then
  [[ "$VERSION" =~ '^[0-9]+(\.[0-9]+)*$' ]] || die "'$VERSION' is not a version number (e.g. 1.2.3)."
  git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && die "tag $VERSION already exists."
  [[ -z "$(git status --porcelain)" ]] || { git status --short >&2; die "uncommitted changes — commit or stash them before releasing."; }
  grep -q 'MARKETING_VERSION = ' "$PROJECT_PATH/project.pbxproj" || die "no MARKETING_VERSION in $PROJECT_PATH/project.pbxproj."
  LATEST_TAG="$(git for-each-ref --sort=-creatordate --count=1 --format='%(refname:short)' refs/tags)"
  printf '%s\n' "${YELLOW}Latest tag:${RESET} ${LATEST_TAG:-(none)} → ${YELLOW}New version:${RESET} $VERSION"
  printf 'Create version %s? [y/N] ' "$VERSION"
  { read -r answer && [[ "$answer" == [yY] ]]; } || { echo "${YELLOW}Aborted.${RESET}" >&2; exit 1; }
  sed -i '' -E "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/" "$PROJECT_PATH/project.pbxproj"
  git add "$PROJECT_PATH/project.pbxproj"
  git commit -m "version: bump to $VERSION"
  echo "${YELLOW}Version:${RESET} $VERSION (committed)"
fi

# Lists the schemes of the project, one per line.
list_schemes() {
  xcodebuild -project "$PROJECT_PATH" -list -json 2>/dev/null \
    | jq -r '.project.schemes[]' || true
}

# Reads the shipped product name straight from the build system, so a rename of
# OSX_APP_NAME needs no edit here. Prints the application bundle name only for
# schemes that build an application; package, helper and test schemes print
# nothing and are therefore never offered.
product_for_scheme() {
  xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$1" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -showBuildSettings -json 2>/dev/null \
    | jq -r '[.[] | select(.buildSettings.PRODUCT_TYPE
                           == "com.apple.product-type.application")][0]
             | .buildSettings.FULL_PRODUCT_NAME' \
    || true
}

# Resolves SCHEME and PRODUCT_BUNDLE together: -s or the SCHEME environment
# variable wins; otherwise only schemes that build an application are numbered
# and the user picks one. A single candidate is used without asking. Assigns
# both SCHEME and PRODUCT_BUNDLE.
resolve_scheme() {
  SCHEME="${SCHEME:-}"
  if [[ -n "$SCHEME" ]]; then
    PRODUCT_BUNDLE="$(product_for_scheme "$SCHEME")"
    return 0
  fi

  local -a names products
  local s p
  for s in "${(@f)$(list_schemes)}"; do
    [[ -n "$s" ]] || continue
    p="$(product_for_scheme "$s")"
    if [[ -n "$p" && "$p" != null ]]; then
      names+=("$s")
      products+=("$p")
    fi
  done

  [[ "${#names[@]}" -gt 0 ]] || die "no scheme in $PROJECT_PATH builds an application (Release)."
  if [[ "${#names[@]}" -eq 1 ]]; then
    SCHEME="${names[1]}"
    PRODUCT_BUNDLE="${products[1]}"
    echo "${YELLOW}Scheme:${RESET} $SCHEME"
    return 0
  fi
  [[ -t 0 ]] || die "several schemes available; use -s or set SCHEME."

  local i choice
  echo "${YELLOW}Select a scheme (1-${#names[@]}):${RESET}"
  for i in {1..${#names[@]}}; do
    printf '  %2d) %s\n' "$i" "${names[i]}"
  done
  read -r choice || die "no selection made."
  [[ "$choice" == <-> && "$choice" -ge 1 && "$choice" -le "${#names[@]}" ]] || die "invalid choice '$choice'."
  SCHEME="${names[choice]}"
  PRODUCT_BUNDLE="${products[choice]}"
}

resolve_scheme

# PRODUCT_BUNDLE comes from the application target of the resolved scheme.
[[ -n "$PRODUCT_BUNDLE" && "$PRODUCT_BUNDLE" != null ]] || die "no application target in scheme $SCHEME (Release)."

APP_NAME="${PRODUCT_BUNDLE%.app}"
DMG_NAME="$APP_NAME.dmg"
ARCHIVE_PATH="build/$APP_NAME.xcarchive"

# Terminal notifications: OSC 9 (iTerm2/Ghostty) plus OSC 777 (opencode).
notify() {
  printf '\x1b]9;%s\x07' "$2"
  printf '\x1b]777;notify;%s;%s\x07' "$1" "$2"
}

# OSC 9;4 progress: status 0 clear, 1 in progress, 2 done, 3 failed.
progress() {
  printf '\x1b]9;4;%s;%s\x07' "$1" "$2"
}

clear_progress() { progress 0 0; }

# Uses the sole choice automatically; otherwise prompts on a terminal.
pick() {
  local prompt="$1" choice
  shift
  [[ "$#" -gt 0 ]] || die "no choices available for $prompt"
  if [[ "$#" -eq 1 ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  [[ -t 0 ]] || die "multiple choices available for $prompt (run interactively or set the env var)."
  echo "${YELLOW}$prompt${RESET}" >&2
  select choice in "$@"; do
    [[ -n "$choice" ]] && break
    echo "${RED}Invalid choice, try again.${RESET}" >&2
  done
  [[ -n "$choice" ]] || die "no selection made (run interactively or set the env vars)."
  printf '%s\n' "$choice"
}

on_error() { progress 3 100; notify "$APP_NAME" "Build failed: $APP_NAME"; }
trap on_error ERR
trap clear_progress EXIT

# 0. Choose the signing team + certificate and the notarization profile once,
#    up front, so the rest of the script runs unattended.
progress 1 5
echo "${BOLD}${CYAN}== Setup: signing and notarization identities ==${RESET}"

IDENTITIES=("${(@f)$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')}")
[[ "${#IDENTITIES[@]}" -gt 0 ]] || die "no Developer ID Application certificate found in the keychain."

TEAMS=()
for id in "${IDENTITIES[@]}"; do
  team="$(printf '%s' "$id" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
  [[ -n "$team" ]] && TEAMS+=("$team")
done
TEAMS=("${(@u)TEAMS}")

if [[ -z "${SIGNING_TEAM:-}" ]]; then
  SIGNING_TEAM="$(pick 'Select a Developer ID team:' "${TEAMS[@]}")"
fi
echo "${YELLOW}Signing team:${RESET} $SIGNING_TEAM"

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  MATCHED=()
  for id in "${IDENTITIES[@]}"; do
    [[ "$id" == *"($SIGNING_TEAM)" ]] && MATCHED+=("$id")
  done
  [[ "${#MATCHED[@]}" -gt 0 ]] || die "no Developer ID certificate for team $SIGNING_TEAM."
  SIGNING_IDENTITY="$(pick "Select a Developer ID certificate for team $SIGNING_TEAM:" "${MATCHED[@]}")"
fi
echo "${YELLOW}Signing identity:${RESET} $SIGNING_IDENTITY"

AUTH_STATUS="$(asc auth status --output json 2>/dev/null || true)"
if [[ -z "${ASC_PROFILE:-}" ]]; then
  PROFILES=("${(@f)$(printf '%s' "$AUTH_STATUS" | jq -r '.credentials[].name')}")
  [[ "${#PROFILES[@]}" -gt 0 ]] || die "no asc credentials found. Run 'asc auth' first."
  ASC_PROFILE="$(pick 'Select an asc credential profile for notarization:' "${PROFILES[@]}")"
fi
echo "${YELLOW}Notarization profile:${RESET} $ASC_PROFILE"

# Bypass the keychain only when the chosen profile is not stored in it
# (i.e. it comes from ~/.asc/config.json or the environment).
STORED_IN="$(printf '%s' "$AUTH_STATUS" | jq -r --arg p "$ASC_PROFILE" \
  '.credentials[] | select(.name == $p) | .storedIn')"
if [[ "$STORED_IN" != "keychain" ]]; then
  export ASC_BYPASS_KEYCHAIN=1
fi

# 1. Archive, signing directly with Developer ID (no re-sign step needed)
echo "${BOLD}${CYAN}== 1/4 Archive (team $SIGNING_TEAM) ==${RESET}"
progress 1 10

asc xcode archive \
  --project "$PROJECT_PATH" \
  --scheme "$SCHEME" \
  --configuration Release \
  --archive-path "$ARCHIVE_PATH" \
  --overwrite \
  --xcodebuild-flag=-quiet \
  --xcodebuild-flag=-destination \
  --xcodebuild-flag=generic/platform=macOS \
  --xcodebuild-flag="CODE_SIGN_STYLE=Manual" \
  --xcodebuild-flag="DEVELOPMENT_TEAM=$SIGNING_TEAM" \
  --xcodebuild-flag="CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
progress 1 45

# 2. Copy the signed .app from the archive into Archives/
echo "${BOLD}${CYAN}== 2/4 Copy signed app ==${RESET}"
progress 1 50
mkdir -p Archives
rm -rf "Archives/$PRODUCT_BUNDLE"
cp -R "$ARCHIVE_PATH/Products/Applications/$PRODUCT_BUNDLE" "Archives/"

# 3. Create the DMG
echo "${BOLD}${CYAN}== 3/4 Create DMG ==${RESET}"
progress 1 65
rm -f "$DMG_NAME"
create-dmg \
--volname "$APP_NAME" \
--background "scripts/dmg-background.jpg" \
--window-pos 200 120 \
--window-size 400 300 \
--icon-size 100 \
--icon "$PRODUCT_BUNDLE" 80 110 \
--hide-extension "$PRODUCT_BUNDLE" \
--app-drop-link 252 110 \
"$DMG_NAME" \
"Archives/"

# 4. Notarize and staple
echo "${BOLD}${CYAN}== 4/4 Notarize (profile $ASC_PROFILE) ==${RESET}"
progress 1 75
ASC_PROFILE="$ASC_PROFILE" asc notarization submit --file "$DMG_NAME" --wait
unset ASC_BYPASS_KEYCHAIN
progress 1 95

xcrun stapler staple "$DMG_NAME"
rm -rf "Archives/$PRODUCT_BUNDLE"
progress 2 100
notify "$APP_NAME" "DMG ready: $DMG_NAME"
open .
echo "${BOLD}${GREEN}DMG created and notarized successfully: $DMG_NAME${RESET}"
