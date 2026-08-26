import re

SRC = '/workspace/starters/coworld-ctf/client/replay_broadcast.html'
OUT = '/workspace/cogame-hidden-agenda/client/replay_broadcast.html'

src = open(SRC).read().split('\n')

# ---------------------------------------------------------------- CSS
# The starter's CSS, verbatim, minus exactly the blocks whose elements the
# design note removes: section 4b (zoom bar + minimap), the POV badge, the
# first-person PiP, the hash-mismatch warning, and the ?viewpanel=0 opt-out.
css = src[0:704] + src[833:1451]
assert css[527].startswith('/* POV eye badge'), css[527]
assert css[703].strip() == '', repr(css[703])
assert css[704].startswith('/* ---------- 5. TRANSPORT'), css[704]
assert css[887].startswith('/* hash-mismatch warning'), css[887]
assert css[903].startswith('#mmwarn.on'), css[903]
css = css[0:527] + css[704:887] + css[904:]
for line in css:
    assert '#fpv' not in line and '#viewpanel' not in line and '#minimap' not in line
    assert '#povBadge' not in line
    assert not line.startswith('#mmwarn')

GAME_CSS = open('/workspace/cogame-hidden-agenda/tools/_page_css.css').read()
MARKUP = open('/workspace/cogame-hidden-agenda/tools/_page_markup.html').read()
SCRIPT = open('/workspace/cogame-hidden-agenda/tools/_page_script.js').read()

page = []
page.append('\n'.join(css))
page.append(GAME_CSS)
page.append('</style>')
page.append('</head>')
page.append('<body>')
page.append(MARKUP)
page.append('<!-- WIRE_CONSTANTS -->')
page.append('<!-- CHROME_COMMON -->')
page.append('<!-- BROADCAST_CORE -->')
page.append('')
page.append('<script>')
page.append(SCRIPT)
page.append('</' + 'script>')
page.append('</body>')
page.append('</html>')
text = '\n'.join(page)
text = text.replace('<title>Ctf \u2014 Broadcast Replay</title>',
                    '<title>Hidden Agenda \u2014 Broadcast Replay</title>')
open(OUT, 'w').write(text)
print('wrote', OUT, len(text.split('\n')), 'lines')
