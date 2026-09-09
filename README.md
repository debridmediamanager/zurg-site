# zurg-site

Source for **[zurg.debridmediamanager.com](https://zurg.debridmediamanager.com/)**, the
landing page for [zurg](https://github.com/debridmediamanager/zurg-public).

Three hand-written pages share `public/site.css`. No framework and no build step.
`public/` holds exactly what ships, so the whole directory is published as-is.

## Layout

```
public/
  index.html         the main landing page
  android.html       Android and TV setup guide
  jellyfin/          Jellyfin plugin guide and images
  site.css           shared typography and responsive layouts
  install.sh         Linux and macOS binary convenience installer
  install-docker.sh  Linux Docker convenience installer
  install.ps1        Windows binary convenience installer
  logo.png           wordmark
  favicon.png        tab icon
  social-card.png    Open Graph / Twitter card
  shot-*.webp        dashboard screenshots
  robots.txt
  sitemap.xml
deploy.sh            ships public/ to Cloudflare Pages or an ssh host
tests/               browser measurements and captured baseline fixtures
```

## Browser verification

Serve `public/` from an isolated directory and port on zen. Attach to an existing
Chrome CDP profile using the workspace browser-driver rules. The test opens and
closes its own tab and disables the browser cache.

```bash
uv run --with websocket-client python tests/dom-layout.py \
  --base-url http://zen:8319 --cdp http://127.0.0.1:9226 --sweep
```

The test replays widths captured from the original public pages and measures
overflow, navigation visibility, supporting text sizes, control heights, image
loading, and keyboard access to scrollable tables. `--sweep` also checks every
40 pixels from 320 through 2560 and a landscape viewport. `--report` saves all
DOM measurements and `--screenshots` saves selected viewport images.

## Deploying

```bash
./deploy.sh pages    # Cloudflare Pages
./deploy.sh host     # scp to a box, restart its unit, health check
```

Settings come from the environment. Copy `deploy.env.example` to `deploy.env` beside
the script (gitignored) and fill it in, or export the variables yourself.

| Variable | Used by | Default |
|---|---|---|
| `CF_PAGES_PROJECT` | `pages` | `zurg` |
| `ZURGSITE_HOST` | `host` | required, `user@box` |
| `ZURGSITE_PATH` | `host` | `'~/zurgsite'`, quote a `~` so the remote expands it |
| `ZURGSITE_SERVICE` | `host` | none, skips the restart |
| `ZURGSITE_HEALTH_URL` | `host` | none, skips the check |

Two things worth knowing.

**A Pages deploy reports success before the edge catches up.** A zone cache rule can
keep serving the previous build for well over an hour. Verify with a cache-busted
fetch and never trust the bare URL:

```bash
curl -s "https://zurg.debridmediamanager.com/?cb=$RANDOM" | grep -o '<h1>.*'
```

Production is about 940 bytes larger than the local file because Cloudflare injects
into the HTML. That delta is normal and is not a failed upload.

**The `host` health check retries on purpose.** The socket is not rebound the instant
`systemctl restart` returns, so the first attempt usually fails.

## Numbers on the page

Every figure is sourced from zurg's own measurements, published in
[zurg's docs](https://notes.debridmediamanager.com/) and the
[usenet streaming benchmark](https://github.com/debridmediamanager/usenet-streaming-benchmark).
Nothing goes on the page that is not traceable to one of them.
