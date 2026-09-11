#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="XFinder"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
OUT_DIR="$ROOT_DIR/release"

cd "$ROOT_DIR"

if [[ -n "${XFINDER_NOTARY_RESUME_ID:-}" && -z "${XFINDER_SIGNING_IDENTITY:-}" ]]; then
    echo "Resuming notarization requires Developer ID release settings." >&2
    exit 1
fi

if [[ -n "${XFINDER_SIGNING_IDENTITY:-}" ]]; then
    : "${XFINDER_NOTARY_PROFILE:?Set the notarization keychain profile for Developer ID releases}"
    xcrun notarytool history --keychain-profile "$XFINDER_NOTARY_PROFILE" --output-format json >/dev/null
elif [[ -n "${XFINDER_NOTARY_PROFILE:-}" ]]; then
    echo "XFINDER_SIGNING_IDENTITY is required for notarization." >&2
    exit 1
fi

VERSION="${XFINDER_VERSION:-${GITHUB_REF_NAME:-}}"
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
fi

if [[ -n "${XFINDER_NOTARY_RESUME_ID:-}" ]]; then
    test -d "$APP_DIR"
elif [[ -n "$VERSION" ]]; then
    XFINDER_VERSION="$VERSION" "$ROOT_DIR/scripts/build-app.sh"
else
    "$ROOT_DIR/scripts/build-app.sh"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME" | tr ' ' '-')"
ZIP_NAME="$APP_NAME-$VERSION-macOS-$ARCHS.zip"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

if [[ -n "${XFINDER_SIGNING_IDENTITY:-}" ]]; then
    SUBMISSION_ID="${XFINDER_NOTARY_RESUME_ID:-}"
    if [[ -z "$SUBMISSION_ID" ]]; then
        # Preserve the upload and submission ID so a slow review can be resumed.
        ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ROOT_DIR/dist/notarization-upload.zip"
        xcrun notarytool submit "$ROOT_DIR/dist/notarization-upload.zip" \
            --keychain-profile "$XFINDER_NOTARY_PROFILE" \
            --output-format json > "$ROOT_DIR/dist/notarization-submission.json"
        SUBMISSION_ID="$(/usr/bin/plutil -extract id raw "$ROOT_DIR/dist/notarization-submission.json")"
    fi
    echo "Notarization submission: $SUBMISSION_ID"
    if ! xcrun notarytool wait "$SUBMISSION_ID" \
        --keychain-profile "$XFINDER_NOTARY_PROFILE" --timeout 5m \
        --output-format json > "$ROOT_DIR/dist/notarization-result.json"; then
        xcrun notarytool info "$SUBMISSION_ID" --keychain-profile "$XFINDER_NOTARY_PROFILE" \
            --output-format json > "$ROOT_DIR/dist/notarization-result.json" || true
        echo "Notarization has not completed successfully. See dist/notarization-result.json." >&2
        echo "Keep dist/XFinder.app and resume with XFINDER_NOTARY_RESUME_ID=$SUBMISSION_ID and the same signing/profile settings." >&2
        exit 1
    fi
    STATUS="$(/usr/bin/plutil -extract status raw "$ROOT_DIR/dist/notarization-result.json")"
    if [[ "$STATUS" != "Accepted" ]]; then
        echo "Notarization status: $STATUS. See dist/notarization-result.json and notarytool log." >&2
        exit 1
    fi
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    spctl --assess --type execute --verbose=4 "$APP_DIR"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$OUT_DIR/$ZIP_NAME"
(cd "$OUT_DIR" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

echo "Built release artifacts:"
echo "  $OUT_DIR/$ZIP_NAME"
echo "  $OUT_DIR/$ZIP_NAME.sha256"
echo
echo "Gatekeeper note:"
if [[ -z "${XFINDER_SIGNING_IDENTITY:-}" ]]; then
    spctl --assess --type execute --verbose=4 "$APP_DIR" 2>&1 || true
fi
