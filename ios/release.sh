#!/bin/zsh
# App Store 提出用の .ipa を作る。
#   ./release.sh            アーカイブ → 書き出し
#   ./release.sh bump       ビルド番号を +1 してからアーカイブ
#
# 書き出した .ipa は Transporter.app か Xcode の Organizer からアップロードする。
# （認証情報をこのスクリプトには持たせない）
set -uo pipefail
cd "$(dirname "$0")"

ARCHIVE="build/TethrTouch.xcarchive"
OUT="build/export"

if [[ "${1:-}" == "bump" ]]; then
  cur=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/[^0-9]//g')
  next=$((cur + 1))
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"$cur\"/CURRENT_PROJECT_VERSION: \"$next\"/" project.yml
  echo "==> build number: $cur -> $next"
fi

echo "==> xcodegen"
xcodegen generate || exit 1

ver=$(grep 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
bld=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
echo "==> version $ver ($bld)"

rm -rf "$ARCHIVE" "$OUT"

echo "==> archive"
xcodebuild archive \
  -project TethrTouch.xcodeproj \
  -scheme TethrTouch \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  | grep -E '^(\*\*|error:|warning: .*deprecat)' || true
[[ -d "$ARCHIVE" ]] || { echo "!! archive failed"; exit 1; }

echo "==> export"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT" \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates \
  | grep -E '^(\*\*|error:)' || true

ipa=$(ls "$OUT"/*.ipa 2>/dev/null | head -1)
if [[ -n "$ipa" ]]; then
  echo
  echo "==> OK: $ipa  ($(du -h "$ipa" | cut -f1))"
  echo "    Transporter.app にドラッグするか、Xcode の Organizer からアップロード"
else
  echo "!! export failed"
  exit 1
fi
