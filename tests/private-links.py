"""Check that no download link leaves a visitor at a private repository's 404.

debridmediamanager/zurg is private: GitHub answers 404 to anyone who is not a
signed-in sponsor. Every link into it must be followed by a way to get access,
so the next link after it has to point at gatekeeper. The download page's file
links (`data-file`) instead share one notice above them, `.dl-404`, which has
to carry that gatekeeper link.

  python3 tests/private-links.py
"""
from html.parser import HTMLParser
from pathlib import Path
import sys

PUBLIC = Path(__file__).resolve().parent.parent / 'public'
PRIVATE = 'https://github.com/debridmediamanager/zurg/'
ACCESS = 'https://gatekeeper.debridmediamanager.com/'


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []
        self.files = []
        self.notice_depth = 0
        self.notice_access = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if self.notice_depth:
            self.notice_depth += 1
        elif 'dl-404' in (attrs.get('class') or '').split():
            self.notice_depth = 1
        if tag == 'a':
            href = attrs.get('href', '')
            self.notice_access |= bool(self.notice_depth) and href == ACCESS
            (self.files if 'data-file' in attrs else self.hrefs).append(href)

    def handle_endtag(self, tag):
        if self.notice_depth:
            self.notice_depth -= 1


failures = []
for page in sorted(PUBLIC.rglob('*.html')):
    parser = Links()
    parser.feed(page.read_text())
    for i, href in enumerate(parser.hrefs):
        if href.startswith(PRIVATE):
            following = parser.hrefs[i + 1] if i + 1 < len(parser.hrefs) else ''
            if following != ACCESS:
                failures.append(f'{page.relative_to(PUBLIC)}: {href} is not followed by a link to {ACCESS}')
    if parser.files and not parser.notice_access:
        failures.append(f'{page.relative_to(PUBLIC)}: download links without a .dl-404 notice linking {ACCESS}')

print('\n'.join(failures) or 'every private link offers a way to get access')
sys.exit(1 if failures else 0)
