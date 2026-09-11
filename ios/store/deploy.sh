#!/bin/zsh
# store/site/ を Cloudflare Pages (tethr.pages.dev) に公開する
set -uo pipefail
cd "$(dirname "$0")"
npx --yes wrangler@latest pages deploy site \
  --project-name tethr --branch main --commit-dirty=true
