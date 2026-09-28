"""Measure every supplied route at the supported responsive viewport matrix.

This is intentionally a small CDP client rather than a test-runner fixture. It
attaches to an existing Chrome profile, never launches a browser, and closes
the one tab it creates. The report keeps the measured boxes so a failure can
be reviewed without guessing from a screenshot.

Example:
  uv run --with websocket-client python tests/responsive_matrix.py \
    --base-url http://zen:8319 --cdp http://127.0.0.1:9226 \
    --routes / /android.html /jellyfin/ --report audit.json \
    --screenshots audit-shots
"""

import argparse
import base64
import itertools
import json
from pathlib import Path
import time
import urllib.request

import websocket


VIEWPORTS = [
    (320, 568),
    (390, 844),
    (430, 932),
    (768, 1024),
    (1024, 768),
    (1280, 800),
    (1440, 900),
    (1920, 1080),
]


class Page:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint.rstrip("/")
        request = urllib.request.Request(self.endpoint + "/json/new?about:blank", method="PUT")
        info = json.load(urllib.request.urlopen(request))
        self.page_id = info["id"]
        self.ws = websocket.create_connection(
            info["webSocketDebuggerUrl"], suppress_origin=True, timeout=45
        )
        self.ids = itertools.count(1)
        self.call("Page.enable")
        self.call("Network.enable")
        self.call("Network.setCacheDisabled", {"cacheDisabled": True})
        self.call("Network.setBypassServiceWorker", {"bypass": True})
        self.call("Emulation.setFocusEmulationEnabled", {"enabled": True})

    def call(self, method, params=None):
        call_id = next(self.ids)
        self.ws.send(json.dumps({"id": call_id, "method": method, "params": params or {}}))
        while True:
            event = json.loads(self.ws.recv())
            if event.get("id") == call_id:
                if "error" in event:
                    raise RuntimeError(event["error"])
                return event.get("result", {})

    def evaluate(self, expression):
        result = self.call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
        )
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"])
        return result.get("result", {}).get("value")

    def viewport(self, width, height):
        self.call(
            "Emulation.setDeviceMetricsOverride",
            {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": False},
        )

    def navigate(self, url):
        self.evaluate("window.__responsiveNavigationPending = true")
        result = self.call("Page.navigate", {"url": url})
        if result.get("errorText"):
            raise RuntimeError(result["errorText"] + ": " + url)
        for _ in range(300):
            time.sleep(0.1)
            if self.evaluate(
                "document.readyState === 'complete' && !window.__responsiveNavigationPending"
            ):
                break
        else:
            raise RuntimeError("Page did not finish loading: " + url)
        self.evaluate("document.fonts.ready.then(() => true)")
        # Client pages fetch their representative content after the document is
        # ready.  Wait for the known loading-only shells to leave the DOM so a
        # measurement never records a transient blank page as a passing route.
        for _ in range(100):
            state = self.evaluate(
                "({title: document.title, body: (document.body?.innerText || '').trim()})"
            )
            if state and state.get("body") not in {
                "Loading...",
                "Loading movies…",
                "Loading TV shows…",
            }:
                break
            time.sleep(0.1)
        time.sleep(1.0)

    def screenshot(self):
        result = self.call("Page.captureScreenshot", {"format": "png"})
        return base64.b64decode(result["data"])

    def close(self):
        self.ws.close()
        urllib.request.urlopen(self.endpoint + "/json/close/" + self.page_id).read()


MEASURE = r"""(() => {
  const width = document.documentElement.clientWidth;
  const height = document.documentElement.clientHeight;
  const visible = el => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const identify = (el, r = el.getBoundingClientRect()) => ({
    tag: el.tagName,
    text: (el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 100),
    id: el.id || '',
    class: typeof el.className === 'string' ? el.className : '',
    box: {left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height},
  });
  const style = el => {
    const s = getComputedStyle(el);
    return {display: s.display, position: s.position, overflowX: s.overflowX,
      overflowY: s.overflowY, fontSize: s.fontSize, lineHeight: s.lineHeight,
      fontWeight: s.fontWeight, color: s.color, backgroundColor: s.backgroundColor,
      textOverflow: s.textOverflow, whiteSpace: s.whiteSpace,
      tabIndex: el.tabIndex, role: el.getAttribute('role') || ''};
  };
  const parseColor = value => {
    const match = value.match(/rgba?\(([^)]+)\)/i);
    if (!match) return null;
    const parts = match[1].split(',').map(part => part.trim());
    if (parts.length < 3) return null;
    const rgb = parts.slice(0, 3).map(part => Number.parseFloat(part));
    if (rgb.some(Number.isNaN)) return null;
    const alpha = parts.length > 3 ? Number.parseFloat(parts[3]) : 1;
    return {rgb, alpha: Number.isNaN(alpha) ? 1 : alpha};
  };
  const composite = (foreground, background) => {
    const alpha = foreground.alpha + background.alpha * (1 - foreground.alpha);
    if (alpha === 0) return {rgb: [0, 0, 0], alpha: 0};
    return {
      rgb: foreground.rgb.map((channel, index) =>
        (channel * foreground.alpha + background.rgb[index] * background.alpha * (1 - foreground.alpha)) / alpha
      ),
      alpha,
    };
  };
  const backgroundFor = el => {
    const bodyBackground = parseColor(getComputedStyle(document.body).backgroundColor) ||
      {rgb: [255, 255, 255], alpha: 1};
    let background = bodyBackground;
    for (let parent = el; parent && parent !== document.documentElement; parent = parent.parentElement) {
      const color = parseColor(getComputedStyle(parent).backgroundColor);
      if (color) {
        background = composite(color, background);
        if (background.alpha >= 0.999) break;
      }
    }
    return background;
  };
  const luminance = color => color.rgb.map(channel => channel / 255).map(channel =>
    channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
  ).reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
  const textCandidates = [...document.querySelectorAll(
    'h1,h2,h3,h4,h5,h6,p,li,td,th,label,figcaption,code,pre,button,a,summary'
  )].filter(el => visible(el) && (el.textContent || '').trim());
  const contrast = textCandidates.map(el => {
    const computed = getComputedStyle(el);
    const foreground = parseColor(computed.color);
    if (!foreground) return null;
    const background = backgroundFor(el);
    const resolvedForeground = composite(foreground, background);
    const ratio = (Math.max(luminance(resolvedForeground), luminance(background)) + 0.05) /
      (Math.min(luminance(resolvedForeground), luminance(background)) + 0.05);
    const fontSize = parseFloat(computed.fontSize);
    const large = fontSize >= 18 || (fontSize >= 14 && Number.parseInt(computed.fontWeight, 10) >= 700);
    return {element: identify(el), ratio, required: large ? 3 : 4.5, fontSize, fontWeight: computed.fontWeight};
  }).filter(Boolean);
  const contrastIssues = contrast.filter(item => item.ratio < item.required);
  const inScroller = el => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const s = getComputedStyle(p);
      if (['auto', 'scroll', 'clip'].includes(s.overflowX) && p.scrollWidth > p.clientWidth + 1) return true;
    }
    return false;
  };
  const all = [...document.querySelectorAll('main, main *, header, header *, footer, footer *, [role="dialog"], [role="menu"]')].filter(visible);
  const allVisible = [...document.querySelectorAll('*')].filter(visible);
  const geometry = all.map(el => ({...identify(el), style: style(el)}));
  const overflow = allVisible.filter(el => !inScroller(el)).filter(el => {
    const r = el.getBoundingClientRect();
    return r.left < -1 || r.right > width + 1;
  }).map(el => identify(el));
  const textNodes = [...document.querySelectorAll('p, li, td, th, label, figcaption, code, pre')].filter(visible);
  const smallText = textNodes.filter(el => parseFloat(getComputedStyle(el).fontSize) < 14).map(el => identify(el));
  const clippedText = textNodes.filter(el => {
    const s = getComputedStyle(el);
    return el.scrollWidth > el.clientWidth + 1 && ['hidden', 'clip'].includes(s.overflowX) &&
      (s.whiteSpace === 'nowrap' || s.textOverflow === 'ellipsis' || s.lineClamp !== 'none');
  }).map(el => identify(el));
  const controls = [...document.querySelectorAll('button, input, select, textarea, summary, nav a, a.btn, a[role="button"], [role="menuitem"]')].filter(visible);
  const smallControls = controls.filter(el => {
    const r = el.getBoundingClientRect();
    return r.height < 43.5 || r.width < 43.5;
  }).map(el => identify(el));
  const navigation = [...document.querySelectorAll('header nav a')].filter(visible);
  const brokenImages = [...document.images].filter(visible).filter(el => el.complete && !el.naturalWidth).map(el => el.src);
  const scrollRegions = [...document.querySelectorAll('*')].filter(visible).filter(el => el.scrollWidth > el.clientWidth + 1).map(el => ({...identify(el), style: style(el)}));
  const badScrollers = scrollRegions.filter(x => x.style.tabIndex < 0 &&
    ['auto', 'scroll'].includes(x.style.overflowX) && !['textarea', 'pre'].includes(x.tag.toLowerCase()));
  const overlapControls = [];
  for (let i = 0; i < controls.length; i++) for (let j = i + 1; j < controls.length; j++) {
    const a = controls[i], b = controls[j];
    if (a.parentElement !== b.parentElement) continue;
    const sa = getComputedStyle(a), sb = getComputedStyle(b);
    if (['absolute', 'fixed', 'sticky'].includes(sa.position) || ['absolute', 'fixed', 'sticky'].includes(sb.position)) continue;
    const ar = a.getBoundingClientRect(), br = b.getBoundingClientRect();
    const x = Math.max(0, Math.min(ar.right, br.right) - Math.max(ar.left, br.left));
    const y = Math.max(0, Math.min(ar.bottom, br.bottom) - Math.max(ar.top, br.top));
    if (x * y > 2) overlapControls.push({a: identify(a), b: identify(b), area: x * y});
  }
  const visibleBoxes = [...document.querySelectorAll('h1,h2,h3,button,input,select,textarea,summary,nav a,a.btn,figure,table,[role="dialog"],[role="menu"]')].filter(visible).map(el => ({...identify(el), style: style(el)}));
  return {
    width, height,
    viewport: {innerWidth: window.innerWidth, innerHeight: window.innerHeight, clientWidth: document.documentElement.clientWidth, clientHeight: document.documentElement.clientHeight},
    scrollWidth: document.documentElement.scrollWidth,
    bodyScrollWidth: document.body.scrollWidth,
    overflow, clippedText, smallText, smallControls, overlapControls, contrast, contrastIssues,
    scrollRegions, badScrollers, navigation: navigation.length, brokenImages,
    heading: document.querySelector('h1')?.textContent.trim() ?? null,
    main: !!document.querySelector('main'),
    title: document.title,
    url: location.href,
    geometry, visibleBoxes,
  };
})()"""


def slug(route):
    cleaned = route.strip("/").replace("/", "-").replace("?", "-").replace("=", "-")
    return cleaned or "home"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--cdp", default="http://127.0.0.1:9222")
    parser.add_argument("--routes", nargs="+", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--screenshots")
    parser.add_argument("--require-main", action="store_true")
    parser.add_argument(
        "--allow-horizontal-scroll",
        action="store_true",
        help="Keep horizontal scroll regions in the report without failing the viewport check.",
    )
    args = parser.parse_args()

    page = Page(args.cdp)
    records = []
    failures = []
    browser = None
    try:
        browser = page.evaluate("navigator.userAgent")
        for route in dict.fromkeys(args.routes):
            target = args.base_url.rstrip("/") + (route if route.startswith("/") else "/" + route)
            for width, height in VIEWPORTS:
                page.viewport(width, height)
                try:
                    page.navigate(target)
                    record = page.evaluate(MEASURE)
                    record.update(route=route, requestedUrl=target, viewportWidth=width, viewportHeight=height)
                    checks = [
                        record["scrollWidth"] <= record["width"] + 1,
                        not record["overflow"], not record["brokenImages"],
                        args.allow_horizontal_scroll or not record["badScrollers"],
                        not record["overlapControls"],
                    ]
                    if args.require_main:
                        checks.extend([record["main"], bool(record["heading"])])
                    record["passed"] = all(checks)
                    if not record["passed"]: failures.append(record)
                    records.append(record)
                    if args.screenshots:
                        destination = Path(args.screenshots)
                        destination.mkdir(parents=True, exist_ok=True)
                        (destination / f"{slug(route)}-{width}x{height}.png").write_bytes(page.screenshot())
                except Exception as error:  # preserve a route blocker in the report
                    record = {"route": route, "requestedUrl": target, "viewportWidth": width,
                              "viewportHeight": height, "passed": False, "error": str(error)}
                    records.append(record); failures.append(record)
            print(f"{route}: {sum(not r['passed'] for r in records if r['route'] == route)} failed viewport checks", flush=True)
    finally:
        page.close()
    report = {"browser": browser, "baseUrl": args.base_url, "viewports": VIEWPORTS,
              "routes": list(dict.fromkeys(args.routes)), "measurements": records}
    Path(args.report).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"{len(records) - len(failures)}/{len(records)} viewport checks passed. Report: {args.report}")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
