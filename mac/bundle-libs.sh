#!/bin/bash
# libgphoto2 一式を .app に取り込み、参照先を @rpath に付け替える。
# これで Homebrew が入っていない Mac でも動く。
#
# 構成:
#   Contents/Frameworks/*.dylib      共有ライブラリ
#   Contents/PlugIns/camlibs/*.so    機種ドライバ（dlopen される）
#   Contents/PlugIns/iolibs/*.so     ポートドライバ（同上）
set -euo pipefail

APP="${1:?使い方: bundle-libs.sh <path/to/Tethr.app>}"
BIN="$APP/Contents/MacOS/Tethr"
FW="$APP/Contents/Frameworks"
PLUG="$APP/Contents/PlugIns"

# バージョン番号のディレクトリを名前順の最後から拾う。
# print-camera-list のような実行ファイルが同居しているので .so の有無で判定する。
find_driver_dir() {
    local base="$1" d
    for d in $(ls -1 "$base" 2>/dev/null | sort -V -r); do
        if ls "$base/$d"/*.so >/dev/null 2>&1; then echo "$base/$d"; return 0; fi
    done
    return 1
}

CAMSRC=$(find_driver_dir /opt/homebrew/lib/libgphoto2) || { echo "camlibs が見つかりません"; exit 1; }
IOSRC=$(find_driver_dir /opt/homebrew/lib/libgphoto2_port) || { echo "iolibs が見つかりません"; exit 1; }

rm -rf "$FW" "$PLUG"
mkdir -p "$FW" "$PLUG/camlibs" "$PLUG/iolibs"
# デジタルフォトフレームとペン型スキャナ用のドライバは同梱しない。
# これらだけが libgd を必要とし、そこから libavif / libaom / libfreetype 等が
# 芋づるで 8MB ほど付いてくる。容量もだが、ライセンスの検討対象が増えるのが重い。
SKIP_CAMLIBS="ax203.so st2205.so tp6801.so docupen.so"
for so in "$CAMSRC"/*.so; do
    name=$(basename "$so")
    case " $SKIP_CAMLIBS " in *" $name "*) continue ;; esac
    cp "$so" "$PLUG/camlibs/"
done
cp "$IOSRC"/*.so  "$PLUG/iolibs/"
echo "  camlibs: $(ls -1 "$PLUG/camlibs" | wc -l | tr -d ' ') 個  ($CAMSRC)"
echo "  iolibs:  $(ls -1 "$PLUG/iolibs"  | wc -l | tr -d ' ') 個  ($IOSRC)"

# Homebrew を指している依存を列挙する
homebrew_deps() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep '^/opt/homebrew' || true
}

# 依存の閉包を Frameworks へ集める。
# dylib 同士がさらに Homebrew を参照するので、打ち止めになるまで繰り返す。
declare -a QUEUE=()
while IFS= read -r f; do QUEUE+=("$f"); done < <(ls "$PLUG"/camlibs/*.so "$PLUG"/iolibs/*.so; echo "$BIN")

copied=""
while [ ${#QUEUE[@]} -gt 0 ]; do
    current="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")
    for dep in $(homebrew_deps "$current"); do
        name=$(basename "$dep")
        if [ ! -f "$FW/$name" ]; then
            src="$dep"
            [ -f "$src" ] || src=$(readlink -f "$dep" 2>/dev/null || echo "$dep")
            cp "$src" "$FW/$name"
            chmod u+w "$FW/$name"
            copied="$copied $name"
            QUEUE+=("$FW/$name")
        fi
    done
done
echo "  同梱した dylib:$copied"

# 参照先の付け替え
retarget() {
    local file="$1"
    for dep in $(homebrew_deps "$file"); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null || true
    done
}

for lib in "$FW"/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null || true
    retarget "$lib"
done

# プラグインは Contents/PlugIns/<種別>/ にあるので、2 階層上って Frameworks へ
for so in "$PLUG"/camlibs/*.so "$PLUG"/iolibs/*.so; do
    retarget "$so"
    install_name_tool -add_rpath "@loader_path/../../Frameworks" "$so" 2>/dev/null || true
done

retarget "$BIN"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true

# 取りこぼしがないか確認
leftover=$( { otool -L "$BIN"; for f in "$FW"/*.dylib "$PLUG"/camlibs/*.so "$PLUG"/iolibs/*.so; do otool -L "$f"; done; } \
            | grep -c '/opt/homebrew' || true )
if [ "$leftover" -gt 0 ]; then
    echo "  ⚠ Homebrew への参照が $leftover 件残っています"
else
    echo "  ✓ Homebrew への参照はすべて解消"
fi
