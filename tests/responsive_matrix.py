"""Measure supplied routes at the complete responsive viewport matrix.

The harness attaches to an existing Chrome profile over CDP. It never starts
Chrome and records geometry, text legibility, content state, and full-page
screenshots. A state manifest and a selector-level scroll allowlist keep
content blockers and intentional scrollers explicit in the report.
"""

import argparse
import base64
import itertools
import json
from pathlib import Path
import re
import time
import urllib.parse
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

    def settle(self, timeout=14.0):
        """Wait for route identity/content to stop changing, not for a fixed delay."""
        deadline = time.monotonic() + timeout
        previous = None
        stable = 0
        latest = None
        while time.monotonic() < deadline:
            latest = self.evaluate(
                r"""(() => {
                  const body = (document.body?.innerText || '').trim();
                  const loading = [...document.querySelectorAll('*')].filter(el =>
                    /loading(?:\.\.\.|…)?/i.test((el.textContent || '').trim()) &&
                    getComputedStyle(el).display !== 'none').length;
                  const pendingImages = [...document.images].filter(img => !img.complete).length;
                  const identity = JSON.stringify({
                    url: location.href,
                    title: document.title,
                    body: body.slice(0, 16000),
                    heading: document.querySelector('h1,h2')?.textContent?.trim() || '',
                    loading,
                    pendingImages,
                  });
                  return {identity, url: location.href, title: document.title, body,
                    loading, pendingImages};
                })()"""
            )
            if latest and latest["identity"] == previous:
                stable += 1
            else:
                stable = 0
            previous = latest["identity"] if latest else None
            if stable >= 3:
                return latest
            time.sleep(0.25)
        return latest or {"url": "", "title": "", "body": "", "loading": 0, "pendingImages": 0}

    def navigate(self, url):
        result = self.call("Page.navigate", {"url": url})
        if result.get("errorText"):
            raise RuntimeError(result["errorText"] + ": " + url)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.evaluate("document.readyState === 'complete'"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Page did not finish loading: " + url)
        self.evaluate("document.fonts?.ready?.then(() => true) || true")
        settled = self.settle()
        # Visit every viewport section once so lazy content and image-backed
        # cards are present before the measurement and full-page capture.
        self.evaluate(
            r"""(async () => {
              const limit = Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0);
              const step = Math.max(window.innerHeight, 240);
              for (let y = 0; y < limit; y += step) {
                window.scrollTo({top: y, behavior: "instant"});
                await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                // Lazy images only start once they near the viewport; give the
                // ones now in view time to arrive before scrolling past them.
                const inView = [...document.images].filter(img => {
                  const r = img.getBoundingClientRect();
                  return !img.complete && r.bottom > 0 && r.top < window.innerHeight;
                });
                await Promise.race([
                  Promise.all(inView.map(img => img.decode().catch(() => null))),
                  new Promise(resolve => setTimeout(resolve, 4000)),
                ]);
              }
              window.scrollTo({top: 0, behavior: "instant"});
              await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
              return true;
            })()"""
        )
        after_reveal = self.settle()
        return after_reveal or settled

    def screenshot_full(self):
        metrics = self.call("Page.getLayoutMetrics")
        css_size = metrics.get("cssContentSize") or metrics.get("contentSize") or {}
        width = max(1, float(css_size.get("width", 1)))
        height = max(1, float(css_size.get("height", 1)))
        result = self.call(
            "Page.captureScreenshot",
            {
                "format": "png",
                "fromSurface": True,
                "captureBeyondViewport": True,
                "clip": {"x": 0, "y": 0, "width": width, "height": height, "scale": 1},
            },
        )
        return base64.b64decode(result["data"])

    def screenshot_tiles(self, width, height, destination):
        scroll = self.evaluate("({height: document.documentElement.scrollHeight, y: window.scrollY})")
        content_height = int(scroll.get("height", height))
        paths = []
        try:
            for index, y in enumerate(range(0, content_height, height)):
                self.evaluate(f"window.scrollTo(0, {y})")
                time.sleep(0.08)
                result = self.call("Page.captureScreenshot", {"format": "png", "fromSurface": True})
                path = destination.with_name(destination.stem + f"-tile-{index:03d}.png")
                path.write_bytes(base64.b64decode(result["data"]))
                paths.append(str(path))
        finally:
            self.evaluate(f"window.scrollTo(0, {scroll.get('y', 0)})")
        return paths

    def close(self):
        self.ws.close()
        urllib.request.urlopen(self.endpoint + "/json/close/" + self.page_id).read()


MEASURE = r"""(() => {
  const width = document.documentElement.clientWidth;
  const height = document.documentElement.clientHeight;
  const visible = el => {
    if (!el) return false;
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    for (let parent = el.parentElement; parent; parent = parent.parentElement) {
      if (parent.tagName === 'DETAILS' && !parent.open) return false;
    }
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' &&
      Number.parseFloat(s.opacity) > 0;
  };
  const directText = el => [...el.childNodes].filter(node => node.nodeType === Node.TEXT_NODE)
    .map(node => node.nodeValue || '').join(' ').trim().replace(/\s+/g, ' ');
  const identify = (el, r = el.getBoundingClientRect()) => ({
    tag: el.tagName,
    text: (directText(el) || (el.textContent || '').trim()).replace(/\s+/g, ' ').slice(0, 160),
    id: el.id || '',
    class: typeof el.className === 'string' ? el.className : '',
    box: {left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height},
  });
  const style = el => {
    const s = getComputedStyle(el);
    return {display: s.display, position: s.position, overflowX: s.overflowX,
      overflowY: s.overflowY, fontSize: s.fontSize, lineHeight: s.lineHeight,
      fontWeight: s.fontWeight, color: s.color, backgroundColor: s.backgroundColor,
      backgroundImage: s.backgroundImage, opacity: s.opacity, textOverflow: s.textOverflow,
      whiteSpace: s.whiteSpace, tabIndex: el.tabIndex, role: el.getAttribute('role') || ''};
  };
  const parseColor = value => {
    if (!value || value === 'transparent') return {rgb: [0, 0, 0], alpha: 0};
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
    return {rgb: foreground.rgb.map((channel, index) =>
      (channel * foreground.alpha + background.rgb[index] * background.alpha * (1 - foreground.alpha)) / alpha), alpha};
  };
  // CSS backgrounds are painted from the document canvas inward. Keep every
  // ancestor in that order; stopping at body or the first opaque node loses a
  // nearer panel background and reports false contrast failures.
  const backgroundFor = el => {
    const chain = [];
    for (let node = el; node; node = node.parentElement) chain.push(node);
    let background = {rgb: [255, 255, 255], alpha: 1};
    const sources = [];
    const needsVisualResolution = [];
    for (const node of chain.reverse()) {
      const computed = getComputedStyle(node);
      const label = node.tagName.toLowerCase() + (node.id ? `#${node.id}` : '');
      if (computed.backgroundImage && computed.backgroundImage !== 'none')
        needsVisualResolution.push({kind: 'background-image', element: label, value: computed.backgroundImage});
      if (Number.parseFloat(computed.opacity) < 1)
        needsVisualResolution.push({kind: 'opacity', element: label, value: computed.opacity});
      const color = parseColor(computed.backgroundColor);
      if (color && color.alpha > 0) {
        background = composite(color, background);
        sources.push({element: label, color, composite: background});
      }
    }
    return {color: background, sources, needsVisualResolution};
  };
  const luminance = color => color.rgb.map(channel => channel / 255).map(channel =>
    channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
  ).reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
  const textElements = new Set();
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) {
    if ((node.nodeValue || '').trim() && visible(node.parentElement)) textElements.add(node.parentElement);
  }
  const controls = [...document.querySelectorAll('button, input, select, textarea, summary, nav a, a.btn, a[role="button"], [role="menuitem"]')].filter(visible);
  for (const control of controls) {
    if (control.getAttribute('aria-label') || control.getAttribute('placeholder') || control.value)
      textElements.add(control);
  }
  const textCandidates = [...textElements].filter(el => visible(el));
  const contrast = textCandidates.map(el => {
    const computed = getComputedStyle(el);
    const foreground = parseColor(computed.color);
    if (!foreground) return null;
    const background = backgroundFor(el);
    const resolvedForeground = composite(foreground, background.color);
    const ratio = (Math.max(luminance(resolvedForeground), luminance(background.color)) + 0.05) /
      (Math.min(luminance(resolvedForeground), luminance(background.color)) + 0.05);
    const fontSize = parseFloat(computed.fontSize);
    const fontWeight = Number.parseInt(computed.fontWeight, 10) || 400;
    const large = fontSize >= 24 || (fontSize >= 18.667 && fontWeight >= 700);
    return {element: identify(el), ratio, required: large ? 3 : 4.5, fontSize,
      fontWeight: computed.fontWeight, foreground, background: background.color,
      backgroundSources: background.sources, needsVisualResolution: background.needsVisualResolution};
  }).filter(Boolean);
  const contrastIssues = contrast.filter(item => item.ratio + 0.001 < item.required && !item.needsVisualResolution.length);
  const contrastVisualReview = contrast.filter(item => item.ratio + 0.001 < item.required && item.needsVisualResolution.length);
  const inScroller = el => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const s = getComputedStyle(p);
      if (['auto', 'scroll', 'clip'].includes(s.overflowX) && p.scrollWidth > p.clientWidth + 1) return true;
    }
    return false;
  };
  const allVisible = [...document.querySelectorAll('*')].filter(visible);
  const all = [...document.querySelectorAll('main, main *, header, header *, footer, footer *, [role="dialog"], [role="menu"]')].filter(visible);
  const geometry = all.map(el => ({...identify(el), style: style(el)}));
  const overflow = allVisible.filter(el => !inScroller(el)).filter(el => {
    const r = el.getBoundingClientRect();
    return r.left < -1 || r.right > width + 1;
  }).map(el => identify(el));
  const smallText = textCandidates.filter(el => parseFloat(getComputedStyle(el).fontSize) < 14).map(el => identify(el));
  const clippedText = textCandidates.filter(el => {
    const s = getComputedStyle(el);
    return el.scrollWidth > el.clientWidth + 1 && ['hidden', 'clip'].includes(s.overflowX) &&
      (s.whiteSpace === 'nowrap' || s.textOverflow === 'ellipsis' || s.lineClamp !== 'none');
  }).map(el => identify(el));
  const intentionalClip = el => el.id === '__next-route-announcer__' ||
    /(^|\s)(truncate|line-clamp-\d+)(\s|$)/.test(typeof el.className === 'string' ? el.className : '') || inScroller(el);
  const clippedTextDefects = textCandidates.filter(el => {
    const s = getComputedStyle(el);
    return el.scrollWidth > el.clientWidth + 1 && ['hidden', 'clip'].includes(s.overflowX) &&
      (s.whiteSpace === 'nowrap' || s.textOverflow === 'ellipsis' || s.lineClamp !== 'none') && !intentionalClip(el);
  }).map(el => identify(el));
  const smallControls = controls.filter(el => {
    const r = el.getBoundingClientRect();
    return r.height < 43.5 || r.width < 43.5;
  }).map(el => identify(el));
  const navigation = [...document.querySelectorAll('header nav a')].filter(visible);
  // A failed image is broken wherever it is. One still loading is broken
  // when it sits in the first screen after the reveal pass has had it in
  // view; further down it can be a card an infinite list appended during
  // that pass, which is recorded but not a failure.
  const loadedBroken = el => el.complete && !el.naturalWidth;
  const stillLoading = el => !el.complete;
  // In the first screen means actually on it: inside the viewport and inside
  // every clipping scroller, since a lazy image off to the side of a
  // horizontal row correctly waits until that row is scrolled.
  const inFirstScreen = el => {
    let r = el.getBoundingClientRect();
    let box = {left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight};
    for (let node = el.parentElement; node && node !== document.body; node = node.parentElement) {
      const cs = getComputedStyle(node);
      if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible') {
        const c = node.getBoundingClientRect();
        box = {left: Math.max(box.left, c.left), top: Math.max(box.top, c.top),
          right: Math.min(box.right, c.right), bottom: Math.min(box.bottom, c.bottom)};
      }
    }
    return r.right > box.left && r.left < box.right && r.bottom > box.top && r.top < box.bottom;
  };
  const brokenImages = [...document.images].filter(visible)
    .filter(el => loadedBroken(el) || (stillLoading(el) && inFirstScreen(el))).map(el => el.src);
  const unloadedImages = [...document.images].filter(visible)
    .filter(el => stillLoading(el) && !inFirstScreen(el)).map(el => el.src);
  const scrollRegions = allVisible.filter(el => el.scrollWidth > el.clientWidth + 1).map(el => ({...identify(el), style: style(el)}));
  const collisionTargets = [...new Set([...controls, ...textCandidates, ...document.querySelectorAll('h1,h2,h3,h4,h5,h6')])].filter(visible);
  const collisionBox = el => {
    if (controls.includes(el)) return el.getBoundingClientRect();
    const ranges = [...el.childNodes].filter(child => child.nodeType === Node.TEXT_NODE && (child.nodeValue || '').trim()).map(child => {
      const range = document.createRange();
      range.selectNodeContents(child);
      return range.getBoundingClientRect();
    }).filter(rect => rect.width > 0 && rect.height > 0);
    if (!ranges.length) return el.getBoundingClientRect();
    return {
      left: Math.min(...ranges.map(rect => rect.left)),
      top: Math.min(...ranges.map(rect => rect.top)),
      right: Math.max(...ranges.map(rect => rect.right)),
      bottom: Math.max(...ranges.map(rect => rect.bottom)),
    };
  };
  const overlapElements = [];
  const positionedCollisions = [];
  const collisionRecord = (a, b, area) => ({a: identify(a), b: identify(b), area,
    aPosition: getComputedStyle(a).position, bPosition: getComputedStyle(b).position});
  for (let i = 0; i < collisionTargets.length; i++) for (let j = i + 1; j < collisionTargets.length; j++) {
    const a = collisionTargets[i], b = collisionTargets[j];
    if (a === b || a.contains(b) || b.contains(a)) continue;
    const ar = collisionBox(a), br = collisionBox(b);
    const x = Math.max(0, Math.min(ar.right, br.right) - Math.max(ar.left, br.left));
    const y = Math.max(0, Math.min(ar.bottom, br.bottom) - Math.max(ar.top, br.top));
    if (x * y <= 2) continue;
    const item = collisionRecord(a, b, x * y);
    const positioned = ['absolute', 'fixed', 'sticky'].includes(item.aPosition) || ['absolute', 'fixed', 'sticky'].includes(item.bPosition);
    if (positioned) positionedCollisions.push(item);
    else if (controls.includes(a) || controls.includes(b)) overlapElements.push(item);
  }
  const visibleBoxes = [...document.querySelectorAll('h1,h2,button,input,select,textarea,summary,nav a,a.btn,figure,table,[role="dialog"],[role="menu"]')].filter(visible).map(el => ({...identify(el), style: style(el)}));
  const bodyText = (document.body?.innerText || '').trim();
  const loading = /\bloading(?:\.\.\.|…)?\b/i.test(bodyText);
  const error = /internal server error|error:\s*failed to load|failed to load data|there was an error|application error|next\.js server error/i.test(bodyText);
  // zurg-site has no sign-in; its guides describe signing in to providers, so
  // matching that copy would misread a guide as a login wall.
  const login = false;
  const empty = /\b(no data available|no results|no .* found|empty library|nothing found)\b/i.test(bodyText);
  const observedState = loading ? 'loading' : error ? 'error' : login ? 'unauthenticated' : empty ? 'empty' : 'rendered';
  return {
    width, height, viewport: {innerWidth: window.innerWidth, innerHeight: window.innerHeight,
      clientWidth: document.documentElement.clientWidth, clientHeight: document.documentElement.clientHeight},
    scrollWidth: document.documentElement.scrollWidth, bodyScrollWidth: document.body.scrollWidth,
    overflow, clippedText, clippedTextDefects, smallText, smallControls, overlapElements,
    positionedCollisions, contrast, contrastIssues, contrastVisualReview, scrollRegions,
    navigation: navigation.length, brokenImages, unloadedImages, heading: document.querySelector('h1')?.textContent.trim() ?? null,
    main: !!document.querySelector('main'), title: document.title, url: location.href,
    observedState, geometry, visibleBoxes,
  };
})()"""


def slug(route):
    cleaned = route.strip("/").replace("/", "-").replace("?", "-").replace("=", "-")
    return cleaned or "home"


def load_json(path):
    if not path:
        return {}
    return json.loads(Path(path).read_text(encoding="utf-8"))


def allowed_scroll(item, route, allowlist):
    for rule in allowlist:
        if rule.get("route") not in (route, "*"):
            continue
        if rule.get("id") and item.get("id") != rule["id"]:
            continue
        if rule.get("tag") and item.get("tag") != rule["tag"]:
            continue
        if rule.get("classContains") and rule["classContains"] not in item.get("class", ""):
            continue
        if rule.get("textIncludes") and rule["textIncludes"] not in item.get("text", ""):
            continue
        return rule.get("reason", "explicit route selector allowance")
    return None


def content_classification(route, requested, observed, manifest):
    """Verify a route from what the page showed, not from the manifest's label.

    The manifest says which states are acceptable and which heading and final
    path identify the page. A route counts as verified only when the observed
    state, the heading and the path all match.
    """
    expected = manifest.get(route, {})
    status = expected.get("status", "unmapped")
    accepted = expected.get("observedStates", ["rendered"] if status == "verified" else [])
    observed_state = observed.get("observedState")
    problems = []
    if observed_state not in accepted:
        problems.append(f"observed {observed_state}, expected one of {accepted}")
    heading = re.sub(r"\s+", " ", observed.get("heading") or "")
    if expected.get("expectHeading") and not re.search(expected["expectHeading"], heading, re.I):
        problems.append(f"heading {heading!r} does not match /{expected['expectHeading']}/")
    path = urllib.parse.urlsplit(observed.get("url") or "").path
    if expected.get("expectPath") and not re.fullmatch(expected["expectPath"], path):
        problems.append(f"ended on {path}, expected {expected['expectPath']}")
    return {
        "expectedState": expected.get("state", "unmapped"),
        "contentStatus": status,
        "contentReason": expected.get("reason", "No route state manifest entry"),
        "observedState": observed_state,
        "observedUrl": observed.get("url"),
        "redirected": observed.get("url") != requested,
        "identityProblems": problems,
        "contentStateMatches": not problems,
        "contentVerified": status == "verified" and not problems,
        "contentBlocked": status == "blocked",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--cdp", default="http://127.0.0.1:9222")
    parser.add_argument("--routes", nargs="+", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--screenshots")
    parser.add_argument("--state-manifest")
    parser.add_argument("--scroll-allowlist")
    parser.add_argument("--require-main", action="store_true")
    args = parser.parse_args()
    manifest = load_json(args.state_manifest)
    allowlist = load_json(args.scroll_allowlist) if args.scroll_allowlist else []
    if isinstance(allowlist, dict):
        allowlist = allowlist.get("rules", [])

    page = Page(args.cdp)
    records = []
    browser = None
    fatal_error = None
    try:
        browser = page.evaluate("navigator.userAgent")
        for route in dict.fromkeys(args.routes):
            target = args.base_url.rstrip("/") + (route if route.startswith("/") else "/" + route)
            for width, height in VIEWPORTS:
                page.viewport(width, height)
                try:
                    settled = page.navigate(target)
                    record = page.evaluate(MEASURE)
                    record.update(route=route, requestedUrl=target, viewportWidth=width, viewportHeight=height,
                                  settle=settled)
                    record.update(content_classification(route, target, record, manifest))
                    allowed = []
                    unallowed = []
                    for region in record["scrollRegions"]:
                        reason = allowed_scroll(region, route, allowlist)
                        (allowed if reason else unallowed).append({**region, **({"reason": reason} if reason else {})})
                    record["allowedScrollRegions"] = allowed
                    record["unallowlistedScrollRegions"] = unallowed
                    clipped_allowed = []
                    clipped_unallowed = []
                    for clipped in record["clippedTextDefects"]:
                        reason = allowed_scroll(clipped, route, allowlist)
                        (clipped_allowed if reason else clipped_unallowed).append(
                            {**clipped, **({"reason": reason} if reason else {})}
                        )
                    record["intentionalClippedText"] = clipped_allowed
                    record["clippedTextDefects"] = clipped_unallowed
                    checks = {
                        "viewportScrollWidth": record["scrollWidth"] <= record["width"] + 1,
                        "overflow": not record["overflow"],
                        "brokenImages": not record["brokenImages"],
                        "horizontalScrollAllowlist": not unallowed,
                        "textClipping": not record["clippedTextDefects"],
                        "peerOverlaps": not record["overlapElements"],
                        "positionedCollisions": not record["positionedCollisions"],
                    }
                    if args.require_main:
                        checks.update(main=record["main"], heading=bool(record["heading"]))
                    record["geometryChecks"] = checks
                    record["geometryPass"] = all(checks.values())
                    record["legibilityPass"] = not record["contrastIssues"] and not record["contrastVisualReview"]
                    record["passed"] = record["geometryPass"] and record["legibilityPass"] and record["contentVerified"]
                    records.append(record)
                    if args.screenshots:
                        destination = Path(args.screenshots)
                        destination.mkdir(parents=True, exist_ok=True)
                        full_path = destination / f"{slug(route)}-{width}x{height}-full.png"
                        try:
                            full_path.write_bytes(page.screenshot_full())
                            record["screenshot"] = str(full_path)
                        except Exception as screenshot_error:
                            tiles = page.screenshot_tiles(width, height, full_path)
                            record["screenshotTiles"] = tiles
                            record["screenshotError"] = str(screenshot_error)
                except Exception as error:
                    record = {"route": route, "requestedUrl": target, "viewportWidth": width,
                              "viewportHeight": height, "passed": False, "geometryPass": False,
                              "contentStatus": "blocked", "contentReason": f"measurement error: {error}",
                              "error": str(error)}
                    records.append(record)
            route_records = [r for r in records if r["route"] == route]
            print(f"{route}: geometry {sum(r.get('geometryPass', False) for r in route_records)}/{len(route_records)}, "
                  f"content verified {sum(r.get('contentVerified', False) for r in route_records)}/{len(route_records)}",
                  flush=True)
    except Exception as error:
        fatal_error = str(error)
    finally:
        try:
            page.close()
        except Exception as error:
            fatal_error = fatal_error or f"browser cleanup: {error}"
    summary = {
        "total": len(records),
        "geometryPasses": sum(record.get("geometryPass", False) for record in records),
        "legibilityPasses": sum(record.get("legibilityPass", False) for record in records),
        "contentVerified": sum(record.get("contentVerified", False) for record in records),
        "contentBlocked": sum(record.get("contentBlocked", False) for record in records),
        "unmapped": sum(record.get("contentStatus") == "unmapped" for record in records),
        "overallPasses": sum(record.get("passed", False) for record in records),
    }
    report = {"browser": browser, "baseUrl": args.base_url, "viewports": VIEWPORTS,
              "routes": list(dict.fromkeys(args.routes)), "summary": summary, "measurements": records,
              "fatalError": fatal_error}
    Path(args.report).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(summary, sort_keys=True))
    print(f"Report: {args.report}")
    raise SystemExit(1 if fatal_error or summary["overallPasses"] != summary["total"] else 0)


if __name__ == "__main__":
    main()
