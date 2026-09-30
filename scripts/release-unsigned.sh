#!/usr/bin/env bash
# Release without a paid Apple Developer account (ad-hoc signed, not notarized).
# Usage: ./scripts/release-unsigned.sh 0.1.1 [--publish]
# Without --publish, only builds the zip locally.
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [--publish]}"
PUBLISH="${2:-}"
REPO="febryardiansyah/coucou"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/coucou-release-$VERSION"
APP="$BUILD_DIR/Coucou.app"
ZIP="$BUILD_DIR/Coucou.zip"

cd "$REPO_ROOT/NotchBuddy"
xcodegen generate
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

xcodebuild \
  -project NotchBuddy.xcodeproj \
  -scheme NotchBuddy \
  -configuration Release \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR"

codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release zip ready: $ZIP"

[ "$PUBLISH" = "--publish" ] || { echo "Dry run done. Re-run with --publish to tag and upload."; exit 0; }

cd "$REPO_ROOT"
git tag "v$VERSION"
git push origin "v$VERSION"

gh release create "v$VERSION" "$ZIP" \
  --repo "$REPO" \
  --title "Coucou $VERSION" \
  --notes "$(cat <<EOF
## Install

1. Download **Coucou.zip**, unzip and move **Coucou.app** to \`/Applications\`.
2. This build is not notarized by Apple, so macOS will block the first launch. Run once in Terminal:

\`\`\`bash
xattr -cr /Applications/Coucou.app
\`\`\`

Or right-click the app → **Open** → **Open** (on macOS 15+: System Settings → Privacy & Security → **Open Anyway**).

## Build from source

\`\`\`bash
brew install xcodegen
git clone https://github.com/$REPO.git
cd coucou/NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
\`\`\`
EOF
)"

echo "✓ v$VERSION released: https://github.com/$REPO/releases/tag/v$VERSION"
