#!/usr/bin/env python3
"""Generates client/replay_broadcast.html from the STARTER's page.

The page is coworld-ctf's `client/replay_broadcast.html` -- its CSS, its body
markup AND its page script -- with this game's block APPENDED under a banner
comment. It is never written from scratch: a page written from scratch that
reuses the starter's ids passes an id test and still ships half the chrome
missing (cogame-gridlock, 2026-08-23), and a page a fraction of the starter's
size IS that rewrite.

Everything this script does to the inherited half is one of:

  1. REMOVALS the design note lists, asserted line by line so a starter bump
     fails loudly instead of silently cutting the wrong block:
       * `#viewpanel` + `#minimap` + `#zoombar` (the board is a fixed 27x19 at
         1080x760 and always fits the frame -- there is nothing to pan to), the
         `?viewpanel=0` opt-out, the board pan/pinch/zoom gestures and the
         zoom keys;
       * `#fpv` and its whole first-person raycaster, plus the eye-level cog
         art it billboards and the `fpmap` wall silhouette it draws;
       * `#povBadge` and `renderPov`;
       * `#mmwarn` and `renderMismatch` (playback records STATE, so there is
         no native/wasm divergence to warn about);
       * the starter's `buildLockerRoom`, whose geometry is baked to the CTF
         bots' pose sheets -- this game's curtain art is five station
         portraits, so the game block builds the scene instead.
  2. The TWO RE-LETTERED LITERALS: the plates' `Lives` label becomes
     `Deposits` / `Crew left`, and the momentum strip's `LIVES LEAD` becomes
     `RACE TO WIN`.
  3. THREE HOOK LINES that let the appended block ride the inherited chrome
     the way the starter's own PAINTBALL block rides it -- `AgendaChrome`
     .install / .frame / .event against an `HA_CTX` built beside `PB_CTX` --
     plus the static bundle's global name (`HiddenAgendaStaticReplay`) and the
     `.plate-name` class item 11 of the acceptance checklist requires.

Nothing else in the starter's markup or script is touched. tests/
test_broadcast.nim asserts the inherited ids, the removed ids, the banner
comment, the alias-scope rule and the inherited transport rules.

    python3 tools/build_page.py
"""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = '/workspace/starters/coworld-ctf/client/replay_broadcast.html'
OUT = os.path.join(ROOT, 'client', 'replay_broadcast.html')

src = open(SRC).read().split('\n')

BANNER = 'HIDDEN-AGENDA additions to the inherited coworld-ctf chrome'


def cut(lines, first, last, expect_first, expect_last):
    """Delete lines[first-1 .. last-1] (1-based, inclusive), asserting both ends."""
    assert lines[first - 1].startswith(expect_first), \
        'line %d is %r, expected %r' % (first, lines[first - 1], expect_first)
    assert lines[last - 1].startswith(expect_last), \
        'line %d is %r, expected %r' % (last, lines[last - 1], expect_last)
    return lines[:first - 1] + lines[last:]


def swap(lines, old, new, count=1):
    """Replace `old` with `new` in exactly `count` lines."""
    hits = [i for i, line in enumerate(lines) if old in line]
    assert len(hits) == count, '%r matched %d lines, expected %d' % (
        old, len(hits), count)
    for i in hits:
        lines[i] = lines[i].replace(old, new)
    return lines


# --------------------------------------------------------------- 1. CSS
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

# --------------------------------------------------------------- 2. MARKUP
# The starter's body, lines 1462..1604 (1-based), with the removed element
# families cut and this game's own elements appended inside #chrome.
markup = src[1461:1604]
assert markup[0] == '<body>', markup[0]
assert '<!-- WIRE_CONSTANTS -->' in markup and '<!-- BROADCAST_CORE -->' in markup
assert markup[-1].strip() == '', repr(markup[-1])
markup = markup[1:]                                   # <body> is emitted below

# #viewpanel (comment + block), #mmwarn, #povBadge, #fpv (comment + block).
markup = cut(markup, 44, 60, '    <!-- View controls', '    </div>')
markup = cut(markup, 45, 70, '    <div id="mmwarn">', '    </div>')

for removed in ('id="viewpanel"', 'id="minimap"', 'id="zoombar"',
                'id="zoom-out"', 'id="zoom-slider"', 'id="zoom-in"',
                'id="zoom-read"', 'id="mmwarn"', 'id="povBadge"',
                'id="fpv"', 'id="fpv-canvas"', 'id="fpv-hud"',
                'id="fpv-map"', 'id="fpv-cap"', 'id="fpv-grip"'):
    for line in markup:
        assert removed not in line, removed

# The curtain is this station's airlock, not the paintball prep room.
markup = swap(markup, 'Pre-load curtain: the bot locker room. The six art frames (srcs set by',
              'Pre-load curtain: the station airlock. The art frames (srcs set by')
markup = swap(markup, 'buildLockerRoom \u2014 the path prefix is delivery-mode dependent) play as a',
              'the appended game block) are five station portraits; the whole')
markup = swap(markup, '~4fps idle loop; the whole scene fades out on the first ingested',
              'scene fades out on the first ingested')
markup = swap(markup, '"Loading replay" while the visual squad preps their markers. -->',
              '"Loading replay" while the crew seals up. -->')
markup = swap(markup, 'Filling hoppers with fresh paint&hellip;',
              'Sealing the airlock&hellip;')
markup = swap(markup, 'Bot locker room &middot; Loading replay',
              'Station airlock &middot; Loading replay')
markup = swap(markup, '>In the locker room<', '>Sealing the airlock<')

# Re-lettered literal 1 of 2: the momentum strip's label.
markup = swap(markup, '>LIVES LEAD<', '>RACE TO WIN<')

# The spoilers button lists the kinds THIS game puts on the timeline.
markup = swap(markup, 'kills / flag story / winner on the timeline',
              'meetings / freezes / ejections / winner on the timeline')

# The appended game block's own elements: the roster strip and the vote board
# ride inside #chrome, band-clipped by their CSS; the role-reveal table rides
# inside the inherited #endcard, above the starter's own #ec-teams panel.
GAME_MARKUP = """
    <!-- %s -->
    <!-- The roster strip (spectator-side role reveal) and the vote board.
         Both are absolutely positioned inside #chrome and clipped to the board
         region between --topband and --band; neither sits in the transport
         band. -->
    <div id="rosterstrip"></div>
    <div id="voteboard">
      <div id="vb-head">MEETING</div>
      <div id="vb-rows"></div>
      <div id="vb-count">RESOLVES IN &mdash;</div>
    </div>
""" % BANNER
anchor = '    <div id="bannerlane"></div>'
assert markup.count(anchor) == 1
markup = '\n'.join(markup).replace(
    anchor, GAME_MARKUP.rstrip('\n') + '\n\n' + anchor).split('\n')

ec_anchor = '      <!-- One stats panel per active team, generated by ensureEndcardTeams(). -->'
assert markup.count(ec_anchor) == 1
markup = '\n'.join(markup).replace(
    ec_anchor,
    '      <!-- %s: the role reveal table. -->\n'
    '      <div id="ec-roles"></div>\n%s' % (BANNER, ec_anchor)).split('\n')

# --------------------------------------------------------------- 3. SCRIPT
# The starter's page script, lines 1605..4342 (1-based) -- <script> through
# </script> -- with the removals above and the three hook lines.
script = src[1604:4342]
assert script[0] == '<script>', script[0]
assert script[-1] == '</script>', script[-1]

# Removals, back to front so the earlier line numbers stay valid.
script = cut(script, 2392, 2665,
             '  // Click a soldier on the board', '')
script = cut(script, 743, 1866, '  // ---------- pov + mismatch', '')
script = cut(script, 479, 512,
             '  // The server ships the static minimap wall silhouette', '')
script = cut(script, 271, 280, '', '  } catch (e) {}')
script = cut(script, 153, 247, '  (function buildLockerRoom() {', '  })();')
script = cut(script, 37, 97,
             '  // ---- eye-level cog art for the EYES PiP billboards',
             '  var cogScratch = document.createElement')

body = '\n'.join(script)


def sub(old, new, count=1):
    global body
    assert body.count(old) == count, '%r matched %d, expected %d' % (
        old, body.count(old), count)
    body = body.replace(old, new)


# The curtain's art is wired by the appended block now (five station
# portraits, not the CTF bots' pose sheets).
sub("""  // ---- pre-load curtain: the bot locker room -------------------------------
  // The stage opens on this scene (see #lockerroom CSS) while the socket /
  // wasm sim boots. The art frames are wired here (their base path is
  // delivery-mode dependent, like the cog art); the first ingested frame
  // calls dismissLockerRoom(), which fades the room out after a short
  // minimum dwell (a sub-second load would otherwise flash the scene like
  // a glitch).""",
    """  // ---- pre-load curtain: the station airlock -------------------------------
  // The stage opens on this scene (see #lockerroom CSS) while the wasm sim
  // boots. The art frames are wired by the APPENDED game block (this game's
  // curtain is five station portraits, so the starter's CTF pose-sheet
  // geometry does not survive); the first ingested frame calls
  // dismissLockerRoom(), which fades the room out after a short minimum dwell
  // (a sub-second load would otherwise flash the scene like a glitch).""")

# The static bundle's adapter global.
sub("var replayAdapter = window.CtfStaticReplay || null;",
    "var replayAdapter = window.HiddenAgendaStaticReplay || null;")

# The view controls are gone, so the core has nobody to report the view to.
sub("""    onFirstFrame: function () { core.setViewportFit(); syncViewUi(); },
    // The core owns the view, so it tells the controls where it ended up —
    // never the other way round. That keeps the slider honest when the zoom
    // moved for some other reason (a pinch, an arrow key, a refit, a new board).
    onTransform: function (t) { syncViewUi(t); }""",
    """    onFirstFrame: function () { core.setViewportFit(); },
    // The zoom cluster and the minimap are removed with #viewpanel (the board
    // always fits the frame), so there are no view controls to keep honest.
    onTransform: function () {}""")

# The three removed per-frame renders.
sub("""    renderScorebug(s);
    renderClock(s);
    renderTransport(s);
    renderPov(s);
    renderMismatch(s);""",
    """    renderScorebug(s);
    renderClock(s);
    renderTransport(s);""")
sub("""    ingestLeadSeries(s);
    ingestFpMap(s);
    ingestLullSpans(s);""",
    """    ingestLeadSeries(s);
    ingestLullSpans(s);""")

# Hook 1 of 3: the appended block renders over the inherited chrome, last.
sub("""    // PAINTBALL additions run last, over the classic chrome's own render.
    if (PB_MODE && window.PaintballChrome) window.PaintballChrome.frame(s, PB_CTX, jumped);""",
    """    // PAINTBALL additions run last, over the classic chrome's own render.
    if (PB_MODE && window.PaintballChrome) window.PaintballChrome.frame(s, PB_CTX, jumped);
    // HIDDEN-AGENDA additions run in the same place and the same way: the
    // classic chrome above has already drawn the plates, the clock, the
    // transport and the scrubber off this game's own `teams` / `roster` /
    // `lead` / `beats` fields, and the block below adds only what this game
    // has that CTF does not.
    if (window.AgendaChrome) window.AgendaChrome.frame(s, HA_CTX, jumped);""")

# Hook 2 of 3: this game's event kinds are routed by the appended block.
sub("""    if (PB_MODE && window.PaintballChrome &&
        window.PaintballChrome.event(e, s, PB_CTX)) {
      beatPulse();
      return;
    }""",
    """    if (PB_MODE && window.PaintballChrome &&
        window.PaintballChrome.event(e, s, PB_CTX)) {
      beatPulse();
      return;
    }
    // Same contract for the HIDDEN-AGENDA kinds (freeze, witness, deposit,
    // fakedeposit, meeting, say, vote, eject, order): the block returns true
    // when it has drawn the row, so the classic switch never doubles it.
    if (window.AgendaChrome && window.AgendaChrome.event(e, s, HA_CTX)) {
      beatPulse();
      return;
    }""")

# The zoom keys and the pov badge went with their elements.
sub("""    else if (k === 'o') setSpoilers(!getSpoilers());
    // Board zoom rides z/x/0: +/- and 1..9 are already the server's speed
    // commands, so they can't double as view keys.
    else if (k === 'z') core.zoomAt(ZOOM_STEP);
    else if (k === 'x') core.zoomAt(1 / ZOOM_STEP);
    else if (k === '0') core.resetView();
    // Arrows walk the view one CELL at a time; with shift, ten cells. A cell is
    // a fixed distance in the WORLD — the same ground on every map and at every
    // zoom — so arrowing is a way of stepping across the arena, not a nudge
    // whose size depends on how far in you happen to be.
    else if (k === 'ArrowLeft' || k === 'ArrowRight' ||
             k === 'ArrowUp' || k === 'ArrowDown') {
      var vt = core.getTransform();
      if (!vt || !(vt.zoom > 1)) return;   // fitted whole: nowhere to go
      ev.preventDefault();
      var step = panCellBoardPx() * (ev.shiftKey ? 10 : 1);
      var stepX = (k === 'ArrowLeft' ? -1 : k === 'ArrowRight' ? 1 : 0);
      var stepY = (k === 'ArrowUp' ? -1 : k === 'ArrowDown' ? 1 : 0);
      core.panByMap(stepX * step, stepY * step);
    }
    else if (k >= '1' && k <= '9') send(k);""",
    """    else if (k === 'o') setSpoilers(!getSpoilers());
    // No z/x/0 and no arrow panning: the board is a fixed 27x19 that always
    // fits the frame, so #viewpanel and every view control went with it.
    else if (k >= '1' && k <= '9') send(k);""")
sub("""  // pov clear (togglePov lives in the shared chrome, driven via ctx.sendPov)
  $('povBadge').addEventListener('click', function () { send('v:-1'); });

""", "")

# Re-lettered literal 2 of 2, plus the .plate-name class the 360px featured
# embed needs on the classic plate (the starter carries it only on its
# paintball plate).
sub("""        '<span class="team-name" id="name-' + team + '">' + team.toUpperCase() + '</span>' +
        '<span class="hcap" id="hcap-' + team + '" style="display:none"></span>' +
        '<span class="lives-label">Lives</span>' +""",
    """        '<span class="team-name plate-name" id="name-' + team + '">' + team.toUpperCase() + '</span>' +
        '<span class="hcap" id="hcap-' + team + '" style="display:none"></span>' +
        '<span class="lives-label">' +
          (team === 'impostor' ? 'Crew left' : 'Deposits') + '</span>' +""")

# Hook 3 of 3: the context the appended block reads the inherited chrome
# through, built beside the starter's own.
sub("""  if (window.PaintballChrome) window.PaintballChrome.install(PB_CTX);

  relayout();""",
    """  if (window.PaintballChrome) window.PaintballChrome.install(PB_CTX);
  // The same context, under this game's name, for the appended block below.
  // It re-implements NONE of this: naming, escaping, the feed queue, the
  // banner lane, the transport and the beat markers all stay up here.
  HA_CTX = PB_CTX;
  if (window.AgendaChrome) window.AgendaChrome.install(HA_CTX);

  relayout();""")
sub("""  var PB_CTX = null;             // filled at the end of this IIFE (hoisted)""",
    """  var PB_CTX = null;             // filled at the end of this IIFE (hoisted)
  var HA_CTX = null;             // the same, for the appended HIDDEN-AGENDA block""")

script = body.split('\n')
for line in script:
    for banned in ('renderFpv', 'renderPov(', 'renderMismatch', 'ingestFpMap',
                   'syncViewUi', 'zoomSlider', 'minimapBox', 'povBadge',
                   'mmwarn', 'ZOOM_STEP', 'panCellBoardPx', 'COG_ART',
                   'CtfStaticReplay'):
        assert banned not in line, '%s survives the removals: %r' % (banned, line)

# --------------------------------------------------------------- 4. ASSEMBLY
GAME_CSS = open(os.path.join(ROOT, 'tools', '_page_css.css')).read()
GAME_SCRIPT = open(os.path.join(ROOT, 'tools', '_page_script.js')).read()

page = []
page.append('\n'.join(css))
page.append('</style>')
page.append('</head>')
page.append('<body>')
page.append('\n'.join(markup))          # carries the starter's own splice markers
page.append('\n'.join(script))
page.append('<!-- ============================================================')
page.append('     ' + BANNER)
page.append('     ============================================================')
page.append('     Everything ABOVE this banner is the starter\'s page: its CSS,')
page.append('     its body markup and its page script, edited only by the')
page.append('     removals, the two re-lettered literals and the three hook')
page.append('     lines tools/build_page.py documents and asserts. Everything')
page.append('     BELOW is this game\'s own block, appended, never a rewrite')
page.append('     that reuses the starter\'s ids (cogame-gridlock, 2026-08-23).')
page.append('     ============================================================ -->')
page.append('<style>')
page.append(GAME_CSS)
page.append('</style>')
page.append('<script>')
page.append(GAME_SCRIPT)
page.append('</' + 'script>')
page.append('</body>')
page.append('</html>')
text = '\n'.join(page)
text = text.replace('<title>Ctf \u2014 Broadcast Replay</title>',
                    '<title>Hidden Agenda \u2014 Broadcast Replay</title>')
open(OUT, 'w').write(text)
print('wrote', OUT, len(text.split('\n')), 'lines')
