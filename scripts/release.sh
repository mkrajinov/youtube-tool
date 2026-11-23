#!/usr/bin/env bash
# Builds a release zip and the matching Homebrew cask in dist/.
#
#   ./scripts/release.sh                 ad-hoc signed build (cask strips the quarantine flag)
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=youtube-tool ./scripts/release.sh
#                                        signed, notarized and stapled build (cask needs no workaround)
#
# NOTARY_PROFILE is a keychain profile made once with:
#   xcrun notarytool store-credentials youtube-tool --apple-id <id> --team-id <TEAMID>
#
# Instead of a profile (CI), an App Store Connect API key:
#   NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<issuer uuid>
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${APP_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUNDLE_ID="io.github.mkrajinov.youtubetool"
APP="YouTubeTool.app"
DIST="dist"
ZIP="$DIST/YouTubeTool-$VERSION.zip"
CASK="$DIST/youtube-tool.rb"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"

notary_auth=()
if [[ -n "$NOTARY_PROFILE" ]]; then
  notary_auth=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "$NOTARY_KEY" ]]; then
  notary_auth=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY needs NOTARY_KEY_ID}" \
               --issuer "${NOTARY_ISSUER:?NOTARY_KEY needs NOTARY_ISSUER}")
fi

if [[ ${#notary_auth[@]} -gt 0 && -z "${SIGN_IDENTITY:-}" ]]; then
  echo "Notarizing needs SIGN_IDENTITY (a Developer ID Application certificate)" >&2
  exit 1
fi

./scripts/build-app.sh release

rm -rf "$DIST"
mkdir -p "$DIST"
# ditto keeps the bundle's symlinks, permissions and signatures intact; plain zip doesn't.
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ ${#notary_auth[@]} -gt 0 ]]; then
  echo "Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$ZIP" "${notary_auth[@]}" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"  # re-zip so the download carries the stapled ticket
  spctl --assess --type execute --verbose "$APP"
  POSTFLIGHT=""
else
  # Ad-hoc builds are not notarized, so Gatekeeper would refuse the quarantined download.
  # Only acceptable in a personal tap; homebrew/cask requires notarized apps.
  POSTFLIGHT='

  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/YouTubeTool.app"]
  end'
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
VERSION="$VERSION" SHA="$SHA" BUNDLE_ID="$BUNDLE_ID" POSTFLIGHT="$POSTFLIGHT" \
  perl -pe 's/\@VERSION\@/$ENV{VERSION}/g; s/\@SHA256\@/$ENV{SHA}/g;
            s/\@BUNDLE_ID\@/$ENV{BUNDLE_ID}/g; s/\@POSTFLIGHT\@/$ENV{POSTFLIGHT}/g' \
  packaging/youtube-tool.rb.in > "$CASK"

cat <<EOF

Release files:
  $ZIP  ($(du -h "$ZIP" | cut -f1), sha256 $SHA)
  $CASK

CI publishes these on every push to main (see README, Release).
EOF
