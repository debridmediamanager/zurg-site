# zurg-site

Source for **[zurg.debridmediamanager.com](https://zurg.debridmediamanager.com/)**, the
landing page for zurg. zurg's public release lives at [zurg-public](https://github.com/debridmediamanager/zurg-public).

Four hand-written pages share `public/site.css`. No framework. `public/` is the English site;
what ships is `dist/`: `public/` plus a translated copy of every page under `/<lang>/` (see Translations).
A push to `main` that touches `public/` deploys it to Cloudflare Pages and purges the edge cache.

## Layout

```
public/
  index.html         the main landing page
  download.html      sponsor downloads, links filled from gatekeeper /api/downloads
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
deploy.sh            builds dist/ and ships it to Cloudflare Pages or an ssh host
i18n/                translate.py (also writes dist/sitemap.xml, every page in every language) and the translation cache
tests/               navigation checks, browser measurements, captured baselines
```

## Navigation

All four pages share one header. The brand comes first, then the link back to
the folder and that page's own sections, then the same five site links in the
same order every time: Download, Android, Jellyfin, Docs, GitHub. The page you are on is
marked with `aria-current="page"`, on the brand for the folder itself. Every
page carries the same footer links, which include the other sites (rex, DMM, sponsor
access) and Discord. Internal links are root-absolute so
they mean the same thing from `/jellyfin/` as from `/`.

Equal item counts are deliberate. They keep the header the same height on every
page, so navigating does not shift the content under it.

```bash
python3 tests/nav-consistency.py
```

No browser and no server. It reads the shipped HTML and fails with one line per
inconsistency.

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

## Installers

```bash
bash tests/test-install-sh.sh
```

```powershell
powershell -NoProfile -File tests\Test-Installer.ps1
pwsh -NoProfile -File tests\Test-Installer.ps1
```

The shell tests load the functions of `install.sh` and `install-docker.sh` and
answer their downloads from the GitHub response recorded in
`tests/fixtures/installer`. Nothing reaches the network. The PowerShell tests
need Windows. The `installer` workflow runs both whenever an installer changes.

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


## Translations

Write English only. Every push to `main` translates what changed into Chinese, Spanish, Arabic, Indonesian,
Portuguese, French, Japanese, Russian and German with `i18n/translate.py` (OpenRouter, repository secret
`OPENROUTER_TRANSLATE_KEY`) and publishes each language under `/<lang>/`. Translations are cached in
`i18n/cache/` by a hash of the English text, so only changed text costs anything; the workflow commits the cache
back as `chore: translations for …`. Do not edit the cache by hand: change the English and the next push
translates it again. Text whose translation fails the checks (code, links, tables or markup changed) is published in
English and tried again on the next push (a warning on the run). If OpenRouter fails (key, monthly limit) the run goes red. The same `translate.py` lives in notes, zurg-site and rex-site; change it in one and copy it
to the other two.

---

**More from DMM:** [Debrid Media Manager](https://debridmediamanager.com/) · [zurg](https://zurg.debridmediamanager.com/) · [rex](https://rex.debridmediamanager.com/) · [Docs](https://notes.debridmediamanager.com/) · [Sponsor](https://gatekeeper.debridmediamanager.com/) · [Discord](https://discord.com/invite/7u4YjMThXP) · [Reddit](https://www.reddit.com/r/debridmediamanager/)
