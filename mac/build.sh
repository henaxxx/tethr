#!/bin/bash
# Tethr.app をビルドして組み立てる。
#   ./build.sh                    リリースビルド（Apple Development で署名）
#   ./build.sh install            ビルドして /Applications に配置
#   ./build.sh release            Developer ID で署名し、公証まで通して配布物を作る
#   ./build.sh release install    公証まで通してから /Applications に配置する
#   SIGN_ID="Developer ID Application: 名前 (TEAMID)" ./build.sh
#                                 配布用の署名（公証にはこちらが必須）
set -euo pipefail
cd "$(dirname "$0")"

APP="Tethr.app"
VERSION="1.0"

# 署名 ID。指定が無ければ手元にあるものを自動で拾う。
if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
fi
if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
fi
[ -z "${SIGN_ID:-}" ] && SIGN_ID="-"   # 最後の手段は ad-hoc

echo "▸ コンパイル"
swift build -c release 2>&1 | grep -vE '^ld: warning: building for macOS' || true

echo "▸ バンドル組み立て"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tethr "$APP/Contents/MacOS/Tethr"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Tethr</string>
    <key>CFBundleDisplayName</key>        <string>Tethr</string>
    <key>CFBundleIdentifier</key>         <string>app.tethr.Tethr</string>
    <key>CFBundleExecutable</key>         <string>Tethr</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>     <string>26.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.photography</string>
    <key>CFBundleDevelopmentRegion</key>  <string>ja</string>
    <key>CFBundleLocalizations</key>
    <array><string>ja</string><string>en</string></array>
</dict>
</plist>
PLIST

echo "▸ 翻訳の同梱"
# SwiftUI は文字列リテラルをそのまま翻訳キーにするため、
# 日本語が基準言語で、en.lproj に対訳を置けば切り替わる。
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "  $(basename "$lproj")"
done

echo "▸ exiftool の同梱"
# exiftool は Perl スクリプト。macOS 標準の Perl で動くので、
# 本体とモジュールだけ入れれば Homebrew 非依存で使える。
# NEF への位置情報書き込みに使う（ImageIO は RAW を書き出せない）。
ETSRC=$(ls -d /opt/homebrew/Cellar/exiftool/*/ 2>/dev/null | sort -V | tail -1)
if [ -n "$ETSRC" ] && [ -f "$ETSRC/bin/exiftool" ]; then
    ETDST="$APP/Contents/Resources/exiftool"
    mkdir -p "$ETDST/lib"
    cp "$ETSRC/bin/exiftool" "$ETDST/exiftool"
    # Image/ だけで動く。Homebrew が同梱している XS モジュール群
    # (darwin-thread-multi-2level, Alien, FFI ほか) は exiftool 本体が使わない。
    cp -R "$ETSRC/libexec/lib/perl5/Image" "$ETDST/lib/"
    # 座標→地名の逆引き DB、各国語の訳語、ドキュメントは書き込みに要らない
    rm -f  "$ETDST/lib/Image/ExifTool/Geolocation.dat"
    rm -rf "$ETDST/lib/Image/ExifTool/Lang"
    find "$ETDST/lib" -name '*.pod' -delete
    chmod -R u+w "$ETDST"
    echo "  exiftool を同梱 ($(du -sh "$ETDST" | cut -f1))"
else
    echo "  ⚠ exiftool が見つかりません。位置情報の書き込みは Homebrew 版に依存します"
fi

echo "▸ ライセンス表記の同梱"
mkdir -p "$APP/Contents/Resources/Licenses"
cat > "$APP/Contents/Resources/Licenses/README.txt" <<LIC
Tethr は以下を同梱しています。

  ExifTool   Artistic / GPL (Perl と同じ条件)  https://exiftool.org

ExifTool は Perl スクリプトとして Contents/Resources/exiftool に同梱しており、
スクリプトそのものがソースコードです。

カメラとのやり取りは macOS の ImageCaptureCore を使っており、ほかのライブラリは同梱していません。
LIC

echo "▸ 署名: $SIGN_ID"
SIGN_ARGS=(--force --timestamp --options runtime --sign "$SIGN_ID")
[ "$SIGN_ID" = "-" ] && SIGN_ARGS=(--force --sign "-")

codesign "${SIGN_ARGS[@]}" "$APP"

echo "▸ 検証"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -2 || true

if [ "${1:-}" = "release" ]; then
    case "$SIGN_ID" in
        "Developer ID Application:"*) ;;
        *) echo "✗ 公証には Developer ID Application 証明書が必要です（現在: $SIGN_ID）"; exit 1 ;;
    esac

    echo "▸ 公証用アーカイブを作成"
    rm -f Tethr.zip
    ditto -c -k --keepParent "$APP" Tethr.zip

    echo "▸ Apple へ提出（数分かかります）"
    xcrun notarytool submit Tethr.zip --keychain-profile "notarytool" --wait

    echo "▸ チケットをアプリに添付"
    # 添付しておくと、利用者がオフラインでも Gatekeeper が検証できる
    xcrun stapler staple "$APP"

    echo "▸ Gatekeeper の判定"
    spctl -a -vvv -t install "$APP" 2>&1 | head -4

    # 添付後のアプリで固め直す
    rm -f Tethr.zip
    ditto -c -k --keepParent "$APP" Tethr.zip
    echo "配布物: $(pwd)/Tethr.zip  ($(du -h Tethr.zip | cut -f1))"

    if [ "${2:-}" = "install" ]; then
        echo "▸ /Applications へ配置（公証済みのものを置く）"
        rm -rf "/Applications/$APP"
        cp -R "$APP" "/Applications/$APP"
        spctl -a -vvv -t install "/Applications/$APP" 2>&1 | head -3
    fi
    exit 0
fi

if [ "${1:-}" = "install" ]; then
    # 公証していないものを置くと Gatekeeper に拒否される。
    # 配布や常用に置くなら ./build.sh release install を使うこと。
    echo "▸ /Applications へ配置（公証なし。手元での動作確認用）"
    rm -rf "/Applications/$APP"
    cp -R "$APP" "/Applications/$APP"
    echo "完了: /Applications/$APP"
else
    echo "完了: $(pwd)/$APP"
fi
