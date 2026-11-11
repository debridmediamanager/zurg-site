#!/usr/bin/env bash
# Deploy the zurg site. Two targets, both shipping public/ plus its translations (built into dist/).
# A push to main already does the Pages deploy (.github/workflows/publish.yml); this is for doing it by hand.
#
#   ./deploy.sh pages   -> Cloudflare Pages
#   ./deploy.sh host    -> any box you can reach over ssh
#
# Settings come from the environment. Put them in deploy.env beside this
# script (gitignored) or export them yourself:
#
#   ZURGSITE_HOST         user@box for the ssh target        (required for: host)
#   ZURGSITE_PATH         remote directory, quote a ~ so the remote expands it
#                                                            (default: '~/zurgsite')
#   ZURGSITE_SERVICE      systemd --user unit to restart     (optional)
#   ZURGSITE_HEALTH_URL   URL to poll once deployed          (optional)
#   CF_PAGES_PROJECT      Cloudflare Pages project name      (default: zurg)
#
# Note on Pages: the deploy reports success as soon as the upload lands, but a
# zone cache rule can keep the edge serving the previous build. Verify with a
# cache-busted fetch (curl 'https://your.domain/?cb=1'), never the bare URL.
set -euo pipefail
cd "$(dirname "$0")"
[ -f deploy.env ] && . ./deploy.env
# Pages under /<lang>/ from the translations in i18n/cache; text not translated yet stays English.
python3 i18n/translate.py html --src public --out dist --host zurg.debridmediamanager.com || [ $? -eq 3 ]

case "${1:-}" in
  host)
    : "${ZURGSITE_HOST:?set ZURGSITE_HOST (user@box), in deploy.env or the environment}"
    remote_path="${ZURGSITE_PATH:-~/zurgsite}"
    # -r so subdirectories under public/ ship too, not just the top-level files.
    scp -qr dist/. "$ZURGSITE_HOST:$remote_path/"
    if [ -n "${ZURGSITE_SERVICE:-}" ]; then
      ssh "$ZURGSITE_HOST" "systemctl --user restart ${ZURGSITE_SERVICE}"
    fi
    if [ -n "${ZURGSITE_HEALTH_URL:-}" ]; then
      # the socket is not rebound the instant systemctl restart returns, so retry
      curl -fsS --retry 5 --retry-delay 1 --retry-all-errors \
        -o /dev/null -w "${ZURGSITE_HEALTH_URL} -> %{http_code}\n" "$ZURGSITE_HEALTH_URL"
    fi
    ;;
  pages)
    # wrangler 4.151 turns `pages` commands into a Workers deploy; 4.40.0 still deploys Pages.
    npx --yes wrangler@4.40.0 pages deploy "$PWD/dist" \
      --project-name="${CF_PAGES_PROJECT:-zurg}" --branch=main --commit-dirty=true
    ;;
  *) echo "usage: $0 [pages|host]" >&2; exit 2 ;;
esac
