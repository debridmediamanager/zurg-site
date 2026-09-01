#!/usr/bin/env bash
# Deploy the zurg site. Two targets, both shipping the contents of public/.
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

case "${1:-}" in
  host)
    : "${ZURGSITE_HOST:?set ZURGSITE_HOST (user@box), in deploy.env or the environment}"
    remote_path="${ZURGSITE_PATH:-~/zurgsite}"
    scp -q public/* "$ZURGSITE_HOST:$remote_path/"
    [ -n "${ZURGSITE_SERVICE:-}" ] && ssh "$ZURGSITE_HOST" "systemctl --user restart ${ZURGSITE_SERVICE}"
    # the socket is not rebound the instant systemctl restart returns, so retry
    [ -n "${ZURGSITE_HEALTH_URL:-}" ] && curl -fsS --retry 5 --retry-delay 1 --retry-all-errors \
      -o /dev/null -w "${ZURGSITE_HEALTH_URL} -> %{http_code}\n" "$ZURGSITE_HEALTH_URL"
    ;;
  pages)
    npx --yes wrangler@latest pages deploy "$PWD/public" \
      --project-name="${CF_PAGES_PROJECT:-zurg}" --branch=main --commit-dirty=true
    ;;
  *) echo "usage: $0 [pages|host]" >&2; exit 2 ;;
esac
