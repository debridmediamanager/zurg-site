"""Check that every page presents the same navigation.

Moving between the three pages must not reshuffle the header. The site-wide
links have to be present, identically labelled, in the same order and pointing
at the same place from every page, and the page you are on has to say so. This
reads the shipped HTML directly, so it needs no browser and no server:

  python3 tests/nav-consistency.py
"""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin
import sys

PUBLIC = Path(__file__).resolve().parent.parent / 'public'
SITE = 'https://zurg.debridmediamanager.com/'

# Every page is served at this URL, ships this file, and calls itself this in
# the shared navigation. A page's own entry is the one that must be current.
PAGES = [
    ('/',             'index.html',          'The folder'),
    ('/android.html', 'android.html',        'Android'),
    ('/jellyfin/',    'jellyfin/index.html', 'Jellyfin'),
]

# The fixed tail of the header navigation. Same labels, same targets, same
# order, always last, on every page. Anything before it is that page's own
# sections plus the link back to the folder.
SHARED_TAIL = [
    ('Android',  SITE + 'android.html'),
    ('Jellyfin', SITE + 'jellyfin/'),
    ('Docs',     'https://notes.debridmediamanager.com/'),
    ('GitHub',   'https://github.com/debridmediamanager/zurg-public'),
]

FOOTER_LINKS = [
    ('zurg',          SITE),
    ('Android',       SITE + 'android.html'),
    ('Jellyfin',      SITE + 'jellyfin/'),
    ('Documentation', 'https://notes.debridmediamanager.com/'),
    ('Sponsor access', 'https://gatekeeper.debridmediamanager.com/'),
]

BRAND = {'class': 'brand', 'aria-label': 'zurg home', 'href': SITE}


class Nav(HTMLParser):
    """Collect the header brand, the header nav links and the footer nav links."""

    def __init__(self, page_url):
        super().__init__(convert_charrefs=True)
        self.page_url = page_url
        self.brand = None
        self.header_links = []
        self.footer_links = []
        self.regions = []          # header / footer nesting
        self.in_nav_links = False
        self.in_footer_nav = False
        self.link = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = (attrs.get('class') or '').split()
        if tag in ('header', 'footer'):
            self.regions.append(tag)
        elif tag == 'nav' and 'nav-links' in classes:
            self.in_nav_links = True
        elif tag == 'nav' and 'footer-nav' in classes:
            self.in_footer_nav = True
        elif tag == 'a':
            href = urljoin(self.page_url, attrs.get('href', ''))
            if self.in_nav_links or self.in_footer_nav:
                self.link = {'text': '', 'href': href, 'raw': attrs.get('href', ''),
                             'current': attrs.get('aria-current')}
            elif self.regions[-1:] == ['header'] and self.brand is None:
                self.brand = {'class': attrs.get('class'), 'aria-label': attrs.get('aria-label'),
                              'href': href, 'current': attrs.get('aria-current')}

    def handle_data(self, data):
        if self.link is not None:
            self.link['text'] += data

    def handle_endtag(self, tag):
        if tag in ('header', 'footer') and self.regions:
            self.regions.pop()
        elif tag == 'nav':
            self.in_nav_links = self.in_footer_nav = False
        elif tag == 'a' and self.link is not None:
            self.link['text'] = ' '.join(self.link['text'].split())
            (self.footer_links if self.in_footer_nav else self.header_links).append(self.link)
            self.link = None


def read(page_url, filename):
    parser = Nav(urljoin(SITE, page_url))
    parser.feed((PUBLIC / filename).read_text(encoding='utf-8'))
    return parser


def main():
    failures = []

    def check(condition, message):
        if not condition:
            failures.append(message)

    parsed = {url: read(url, filename) for url, filename, _ in PAGES}
    counts = set()

    for url, filename, own_label in PAGES:
        nav = parsed[url]
        where = filename
        header = nav.header_links
        labels = [link['text'] for link in header]
        counts.add(len(header))

        # The brand is the same control on every page.
        check(nav.brand is not None, f'{where}: no brand link in the header')
        for key, want in BRAND.items():
            got = (nav.brand or {}).get(key)
            check(got == want, f'{where}: brand {key} is {got!r}, every page needs {want!r}')

        # The shared tail: same labels, same targets, same order, always last.
        tail = header[-len(SHARED_TAIL):]
        got_tail = [(link['text'], link['href']) for link in tail]
        check(got_tail == SHARED_TAIL,
              f'{where}: header nav must end with {SHARED_TAIL}, got {got_tail}')

        # Every page reaches every other page from its header.
        targets = {link['href'] for link in header} | {(nav.brand or {}).get('href')}
        for other, _, other_label in PAGES:
            check(urljoin(SITE, other) in targets,
                  f'{where}: header nav has no link to {other_label} ({other})')

        # The page you are on says so, exactly once. The folder is the brand's
        # own destination, so there the brand carries the marker instead.
        current = [link['text'] for link in header if link['current'] == 'page']
        if (nav.brand or {}).get('current') == 'page':
            current.append('the brand')
        want_current = ['the brand'] if url == '/' else [own_label]
        check(current == want_current,
              f'{where}: aria-current="page" should mark {want_current}, marks {current}')

        # Root-absolute internal hrefs, so a link means the same from /jellyfin/.
        for link in header + nav.footer_links:
            raw = link['raw']
            check(raw.startswith(('/', '#', 'https://', 'http://')),
                  f'{where}: {link["text"]!r} uses {raw!r}, internal links must be root-absolute')

        # One footer, same five links, everywhere.
        got_footer = [(link['text'], link['href']) for link in nav.footer_links]
        check(got_footer == FOOTER_LINKS,
              f'{where}: footer nav must be {FOOTER_LINKS}, got {got_footer}')

        # Nothing named twice in one header.
        check(len(set(labels)) == len(labels), f'{where}: duplicate header nav labels in {labels}')

    # Equal item counts keep the header the same height on every page.
    check(len(counts) == 1,
          f'header nav item counts differ across pages: '
          f'{ {f: len(parsed[u].header_links) for u, f, _ in PAGES} }')

    for failure in failures:
        print('FAIL', failure)
    print(f'{len(failures)} navigation inconsistencies across {len(PAGES)} pages')
    raise SystemExit(1 if failures else 0)


if __name__ == '__main__':
    main()
