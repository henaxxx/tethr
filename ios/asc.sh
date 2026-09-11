#!/bin/zsh
# App Store Connect への投入。fastlane のラッパー。
#
#   ./asc.sh create_app     アプリのレコードを作る（初回のみ）
#   ./asc.sh metadata       掲載文を反映
#   ./asc.sh shots          スクリーンショットを反映
#   ./asc.sh upload_build   .ipa をアップロード
#   ./asc.sh push_all       まとめて反映
#
# 事前に App Store Connect API キーの場所を環境変数で渡すこと:
#   export ASC_KEY_ID=XXXXXXXXXX
#   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   export ASC_KEY_PATH=~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8
set -uo pipefail
cd "$(dirname "$0")"

# fastlane は UTF-8 でないと日本語のメタデータが壊れる
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

lane="${1:-}"
if [[ -z "$lane" ]]; then
  echo "使い方: ./asc.sh {create_app|metadata|shots|upload_build|push_all}"
  exit 1
fi

# 認証は (A) API キー か (B) Apple ID のどちらか
have_key=1
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
  [[ -z "${(P)v:-}" ]] && have_key=0
done

if (( have_key )); then
  key="${ASC_KEY_PATH/#\~/$HOME}"
  if [[ ! -f "$key" ]]; then
    echo "!! 鍵が見つかりません: $ASC_KEY_PATH"
    exit 1
  fi
elif [[ -n "${FASTLANE_USER:-}" ]]; then
  : # Apple ID 方式。2FA は fastlane が聞いてくる
else
  cat <<'MSG'
!! 認証情報がありません。次のどちらかを設定してください。

 (A) App Store Connect API キー  ... 2FA 不要・期限なし
     export ASC_KEY_ID=XXXXXXXXXX
     export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
     export ASC_KEY_PATH=~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8

     ※ .p8 は作成直後の一度しか落とせません。落としそこねたキーは
       取り消して作り直してください。

 (B) Apple ID                    ... .p8 が無いときはこちら
     export FASTLANE_USER=hina0902suzuki@icloud.com

     2FA を毎回聞かれるのが嫌なら、先に一度だけ:
       fastlane spaceauth -u hina0902suzuki@icloud.com
     を実行し、出力された FASTLANE_SESSION を export（約30日有効）。
MSG
  exit 1
fi

exec fastlane ios "$lane"
