"""Check that no download link leaves a visitor at a private repository's 404.

debridmediamanager/zurg is private: GitHub answers 404 to anyone who is not a
signed-in sponsor. Every link into it must be followed by a way to get access,
so the next link after it has to point at gatekeeper.

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

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            self.hrefs.append(dict(attrs).get('href', ''))


failures = []
for page in sorted(PUBLIC.rglob('*.html')):
    parser = Links()
    parser.feed(page.read_text())
    for i, href in enumerate(parser.hrefs):
        if href.startswith(PRIVATE):
            following = parser.hrefs[i + 1] if i + 1 < len(parser.hrefs) else ''
            if following != ACCESS:
                failures.append(f'{page.relative_to(PUBLIC)}: {href} is not followed by a link to {ACCESS}')

print('\n'.join(failures) or 'every private link offers a way to get access')
sys.exit(1 if failures else 0)
