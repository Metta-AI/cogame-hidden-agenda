(function () {
  'use strict';

  // ============================================================
  //  HIDDEN-AGENDA additions to the inherited coworld-ctf chrome.
  // ============================================================
  //  Everything above the banner comment is the starter's page. It has already
  //  drawn, off this game's own frame contract, everything CTF and Hidden
  //  Agenda have in common: the two plates and their numerals (the starter's
  //  `teams` / `roster` machinery, keyed `crew` and `impostor`), the clock, the
  //  transport bar, the speed chips, the scrubber, the lull shading, the
  //  spoilers gate, the momentum strip (the race series in the starter's own
  //  `lead` shape), the kill feed queue, the banner lane queue, the endcard and
  //  the locker-room curtain.
  //
  //  This block adds ONLY what this game has that CTF does not: the two plate
  //  sublines, the roster strip with the spectator role reveal, the vote board,
  //  the CAUGHT! banner, one feed-row builder per event kind the sim emits, the
  //  role-reveal table on the endcard, the curtain's station portraits and the
  //  labelled, clickable scrubber beats.
  //
  //  It re-implements NOTHING from up there. Naming, escaping, feed insertion,
  //  the banner queue, the transport and the beat markers are all reached
  //  through the context the inherited script hands to install(), exactly as
  //  the starter's own PAINTBALL block reaches them.
  //
  //  NOTE the beat builder is called buildAgendaBeats, NEVER markBeat: a
  //  game-block `function markBeat` is hoisted over the chrome alias block's
  //  own `var markBeat = C.markBeat` and silently kills every scrubber beat
  //  (cogame-tandem, 2026-08-23). tests/test_broadcast.nim asserts the whole
  //  alias list is untouched below this banner.
  // ============================================================

  var CTX = null;

  // NOT named `$`: the inherited script aliases the shared chrome's own `$`
  // with a hoisted `var`, and tests/test_broadcast.nim forbids any game-block
  // function whose name collides with that alias list.
  function byId(id) { return document.getElementById(id); }

  // ---- names and colours -------------------------------------------------
  function agenda(s) { return (s && s.agenda) || {}; }
  function aliasOf(s, slot) {
    var r = (s.roster || [])[slot];
    return (r && r.name) || ('#' + slot);
  }
  function policyOf(s, slot) {
    var r = (s.roster || [])[slot];
    return (r && r.pol) || '';
  }
  function slotOfAlias(s, alias) {
    var roster = s.roster || [];
    for (var i = 0; i < roster.length; i++) {
      if (roster[i].name === alias) return roster[i].s;
    }
    return -1;
  }
  var BODY_COLOURS = ['#e0523a', '#3f7cc4', '#45a85e', '#ddc531', '#d96ab0'];
  function colourOfAlias(s, alias) {
    var slot = slotOfAlias(s, alias);
    return slot >= 0 ? BODY_COLOURS[slot % BODY_COLOURS.length]
      : (CTX ? CTX.C.AMBER : '#e8a33d');
  }
  function roomWords(name) { return String(name || '').toUpperCase(); }
  function htmlEsc(text) { return CTX.esc(text); }

  // ============================================================
  //  The curtain. The starter's #lockerroom markup and CSS are inherited
  //  whole; only the scene inside it is this game's - the station plate and
  //  five colour portraits, sitting where the CTF pose carousels sat.
  // ============================================================
  var CURTAIN_ART = './art/lockerroom/';
  var CURTAIN_COGS = ['red', 'blue', 'green', 'yellow', 'pink'];
  function buildCurtain() {
    var bg = byId('lk-bg');
    var sprites = byId('lk-sprites');
    if (!bg || !sprites) return;
    bg.src = CURTAIN_ART + 'bg.jpg';
    CURTAIN_COGS.forEach(function (colour, index) {
      var wrap = document.createElement('div');
      wrap.className = 'lk-boto';
      wrap.style.left = (9 + index * 17) + '%';
      wrap.style.top = '52%';
      wrap.style.width = '15%';
      wrap.style.height = '26%';
      var img = document.createElement('img');
      img.alt = '';
      img.src = CURTAIN_ART + colour + '.png';
      img.style.width = '100%';
      img.style.setProperty('--cyc', (3.6 + index * 0.4) + 's');
      wrap.appendChild(img);
      sprites.appendChild(wrap);
    });
    function fit() {
      sprites.style.left = bg.offsetLeft + 'px';
      sprites.style.top = bg.offsetTop + 'px';
      sprites.style.width = bg.offsetWidth + 'px';
      sprites.style.height = bg.offsetHeight + 'px';
    }
    bg.addEventListener('load', fit);
    if (window.ResizeObserver) new ResizeObserver(fit).observe(bg);
    window.addEventListener('resize', fit);
    fit();
  }

  // ============================================================
  //  Plate sublines. The inherited renderScorebug has already set both plate
  //  names, both numerals (crew = deposits, impostor = crew left, straight off
  //  the frame's `teams`) and both squad strips. The sublines are this game's:
  //  "21 / 32" under the crew plate, and the impostor's alias + policy with a
  //  freeze-cooldown pip bar under the other.
  // ============================================================
  function subline(team) {
    var plate = document.querySelector('.plate[data-team="' + team + '"]');
    if (!plate) return null;
    var el = plate.querySelector('.ha-sub');
    if (!el) {
      el = document.createElement('div');
      el.className = 'ha-sub';
      var id = plate.querySelector('.team-id');
      (id || plate).appendChild(el);
    }
    return el;
  }

  function pipBar(value, total, count) {
    // `value` is TICKS REMAINING, so a full bar is a ready beam and an empty
    // one is a beam that just fired.
    var on = total > 0 ? Math.round((1 - value / total) * count) : count;
    var html = '<span class="cooldown">';
    for (var i = 0; i < count; i++) {
      html += '<i class="' + (i < on ? 'on' : '') + '"></i>';
    }
    return html + '</span>';
  }

  function renderSublines(s) {
    var a = agenda(s);
    var crew = subline('crew');
    var impostor = subline('impostor');
    if (crew) {
      crew.textContent = (a.dep === undefined ? 0 : a.dep) + ' / ' +
        (a.tgt || 32);
    }
    if (impostor) {
      var alias = a.imp >= 0 ? aliasOf(s, a.imp) : '?';
      var policy = a.imp >= 0 ? policyOf(s, a.imp) : '';
      impostor.innerHTML = htmlEsc(alias) +
        (policy ? ' &middot; ' + htmlEsc(policy) : '') +
        pipBar(a.cool || 0, a.coolMax || 260, 5);
    }
  }

  // ---- the clock caption: spelled out, never "M4" ------------------------
  function renderCaption(s) {
    var a = agenda(s);
    var el = byId('clock-caption');
    if (!el) return;
    byId('clock-time').textContent = 'TICK ' + s.t + ' / ' + (s.mt || s.mx);
    if (s.ph === 'gameover') {
      el.textContent = 'FINAL';
    } else if (a.m && a.m.phase > 0) {
      var stage = a.m.phase >= 5 ? 'RESOLVED'
        : (a.m.phase >= 4 ? 'VOTES CHANGING'
          : (a.m.phase >= 3 ? 'VOTING' : 'MEETING CALLED'));
      el.textContent = 'MEETING ' + a.m.n + ' \u2014 ' + stage;
    } else {
      el.textContent = 'DEPOSITS ' + (a.dep || 0) + ' / ' + (a.tgt || 32);
    }
  }

  // ============================================================
  //  Roster strip: five chips under the scorebug, each with its body colour,
  //  a state glyph and - spectator-side ONLY - a red ring on the impostor.
  // ============================================================
  var rosterKey = '';
  function renderRoster(s) {
    var a = agenda(s);
    var states = a.states || [];
    var key = (s.roster || []).map(function (r) { return r.name + r.pol; })
      .join('|') + '#' + states.join(',') + '#' + a.imp;
    if (key === rosterKey) return;
    rosterKey = key;
    var host = byId('rosterstrip');
    if (!host) return;
    var html = '';
    (s.roster || []).forEach(function (r, i) {
      var state = states[i] || 'active';
      var glyph = state === 'frozen' ? '\u2744'
        : (state === 'ejected' ? '\u2715' : '\u25cf');
      html += '<span class="rchip ' + state +
        (i === a.imp ? ' imp' : '') + '" style="--tc:' +
        colourOfAlias(s, r.name) + '">' +
        '<span class="rglyph">' + glyph + '</span>' +
        '<span class="ralias">' + htmlEsc(r.name) + '</span>' +
        (r.pol ? '<span class="rpol">' + htmlEsc(r.pol) + '</span>' : '') +
        '</span>';
    });
    host.innerHTML = html;
  }

  // ============================================================
  //  Vote board: one VOTER -> TARGET row per active seat, greyed until the
  //  reveal tick, filled simultaneously, flipped to amber on any row that
  //  changes at the switch tick, with the resolve countdown under it. This is
  //  where "live vote changes in the last ticks" is legible.
  // ============================================================
  var voteSnapshot = {};
  var SHORT = { RED: 'RED', BLUE: 'BLU', GREEN: 'GRN', YELLOW: 'YEL',
    PINK: 'PNK' };
  function shortAlias(alias) {
    return SHORT[alias] || String(alias).slice(0, 3);
  }
  function renderVoteBoard(s) {
    var a = agenda(s);
    var board = byId('voteboard');
    if (!board) return;
    var meeting = a.m || {};
    var on = (meeting.phase || 0) > 0;
    board.classList.toggle('on', on);
    if (!on) { voteSnapshot = {}; return; }
    var tiny = byId('stage').classList.contains('tiny');
    byId('vb-head').textContent = 'MEETING ' + (meeting.n || 0) + ' \u2014 ' +
      (meeting.cause === 'witness' ? 'WITNESSED FREEZE' : 'SCHEDULED');
    var votes = meeting.votes || {};
    var tally = meeting.tally || {};
    var states = a.states || [];
    var html = '';
    (s.roster || []).forEach(function (r, i) {
      if (states[i] === 'frozen' || states[i] === 'ejected') return;
      var target = votes[r.name];
      var changed = voteSnapshot[r.name] !== undefined &&
        voteSnapshot[r.name] !== target && target !== undefined;
      var name = tiny ? shortAlias(r.name) : r.name;
      var to = target === undefined ? '\u2014'
        : (target === 'skip' ? 'SKIP' : (tiny ? shortAlias(target) : target));
      html += '<div class="vrow' + (target !== undefined ? ' filled' : '') +
        (changed ? ' switched' : '') + '" style="--tc:' +
        colourOfAlias(s, r.name) + '">' +
        '<span class="vfrom">' + htmlEsc(name) + '</span>' +
        '<span class="varrow">&rarr;</span>' +
        '<span class="vto">' + htmlEsc(to) + '</span>' +
        '<span class="vtally">' + (tally[r.name] ? '\u25cf'.repeat(
          Math.min(4, tally[r.name])) : '') + '</span>' +
        '</div>';
    });
    byId('vb-rows').innerHTML = html;
    byId('vb-count').textContent = meeting['in'] > 0
      ? 'RESOLVES IN ' + meeting['in'] : 'RESOLVED';
    voteSnapshot = {};
    Object.keys(votes).forEach(function (k) { voteSnapshot[k] = votes[k]; });
  }

  // ============================================================
  //  Feed rows and banners, one builder per event kind the sim emits. Rows go
  //  into the INHERITED queue through ctx.pushFeed(row) - one argument, the row
  //  element, the starter's own signature, never a re-implementation (cogball
  //  0.1.4) - and banners through ctx.banner(text, cls).
  // ============================================================
  function feedRow(html, cls) {
    var row = document.createElement('div');
    row.className = 'feed-row' + (cls ? ' ' + cls : '');
    row.innerHTML = html;
    CTX.pushFeed(row);
  }

  function applyAgendaEvent(e, s) {
    var tint = function (alias) {
      return '<span style="color:' + colourOfAlias(s, alias) + '">' +
        htmlEsc(alias) + '</span>';
    };
    switch (e.k) {
      case 'freeze':
        var victim = e.victim;
        var freezer = aliasOf(s, e.seat);
        var where = roomWords(e.room || '');
        if (e.witnesses && e.witnesses.length) {
          CTX.banner('CAUGHT! ' + freezer + ' FROZE ' + victim + ' \u2014 ' +
            e.witnesses.join(' + ') + ' SAW IT', 'caught');
        } else {
          CTX.banner(victim + ' WAS FROZEN \u2014 NOBODY SAW IT', 'quiet');
        }
        feedRow(tint(freezer) + ' FROZE ' + tint(victim) +
          (where ? ' IN ' + htmlEsc(where) : ''), 'flagkill');
        return true;
      case 'witness':
        feedRow(tint(e.witness) + ' SAW IT');
        return true;
      case 'deposit':
        if (e.total % 4 === 0) {
          feedRow('DEPOSITS ' + e.total + ' / ' + (agenda(s).tgt || 32));
        }
        return true;
      case 'fakedeposit':
        feedRow(tint(aliasOf(s, e.seat)) +
          ' DROPPED A GEM &mdash; THE COUNTER DIDN\u2019T MOVE');
        return true;
      case 'meeting':
        CTX.banner('MEETING ' + e.n + ' CALLED \u2014 ' +
          (e.cause === 'witness' ? 'WITNESSED FREEZE' : 'SCHEDULED'),
          'meeting');
        feedRow('MEETING ' + e.n + ' CALLED &mdash; ' +
          (e.cause === 'witness' ? 'WITNESSED FREEZE' : 'SCHEDULED'));
        return true;
      case 'say':
        feedRow(tint(aliasOf(s, e.seat)) + ' &ldquo;' + htmlEsc(e.text) +
          '&rdquo;');
        return true;
      case 'vote':
        feedRow(tint(aliasOf(s, e.seat)) +
          (e.phase === 'switch' ? ' SWITCHED &rarr; ' : ' &rarr; ') +
          htmlEsc(e.target === 'skip' ? 'SKIP' : e.target));
        return true;
      case 'eject':
        if (e.target) {
          var counts = [];
          Object.keys(e.tally || {}).forEach(function (k) {
            counts.push(e.tally[k]);
          });
          counts.sort(function (x, y) { return y - x; });
          var score = counts.length > 1 ? counts[0] + '-' + counts[1]
            : String(counts[0] || 0);
          feedRow(tint(e.target) + ' EJECTED ' + score + ' &mdash; ' +
            (e.wasImpostor ? 'THE IMPOSTOR' : 'CREW'),
            e.wasImpostor ? 'flagkill' : '');
          CTX.banner(e.target + ' EJECTED \u2014 ' +
            (e.wasImpostor ? 'THE IMPOSTOR' : 'A CREWMATE'),
            e.wasImpostor ? 'caught' : 'quiet');
        } else {
          feedRow('NOBODY EJECTED &mdash; ' + htmlEsc(String(e.outcome)
            .toUpperCase()));
        }
        return true;
      case 'order':
        var steps = (e.plan || []).map(function (p) {
          return p.job + (p.at ? ' ' + p.at : '') +
            (p.who ? ' ' + p.who : '') + (p.room ? ' ' + p.room : '');
        }).join(', ');
        var tag = (e.source === 'fallback' || e.source === 'scripted' ||
          e.source === 'budget') ? ' <span class="badge">auto</span>' : '';
        feedRow(tint(aliasOf(s, e.seat)) + ' &rarr; ' + htmlEsc(steps) +
          (e.hunch ? ' &ldquo;' + htmlEsc(e.hunch) + '&rdquo;' : '') + tag);
        return true;
      default:
        return false;
    }
  }

  // ============================================================
  //  Scrubber beats. buildAgendaBeats ingests state.beats on the first HUD
  //  frame and calls the INHERITED chrome's markBeat for each (through the
  //  context, so this block never shadows the alias); upgradeBeatButtons is the
  //  post-pass that turns every placed .beat-marker div into a LABELLED,
  //  CLICKABLE button wired to seek(tick). There is CSS for every kind the game
  //  emits - meeting, freeze, caught, eject, deposit, gameover - and no others
  //  are emitted.
  // ============================================================
  var beatsIngested = false;
  var beatLabels = {};
  function buildAgendaBeats(s) {
    if (beatsIngested || !s.beats) return;
    beatsIngested = true;
    for (var i = 0; i < s.beats.length; i++) {
      var b = s.beats[i];
      var label;
      switch (b.k) {
        case 'meeting': label = 'Meeting ' + (b.n || '') + ' at tick ' + b.t;
          break;
        case 'freeze': label = (b.who || 'a crewmate') + ' frozen at tick ' +
          b.t; break;
        case 'caught': label = 'Witnessed freeze at tick ' + b.t; break;
        case 'eject': label = (b.who || 'somebody') + ' ejected at tick ' +
          b.t; break;
        case 'deposit': label = 'Deposit ' + (b.n || '') + ' at tick ' + b.t;
          break;
        case 'gameover': label = 'Game over at tick ' + b.t; break;
        default: label = b.k + ' at tick ' + b.t; break;
      }
      beatLabels[b.t + '|' + b.k] = label;
      CTX.C.markBeat(b.t, b.k, '');
      if (b.k === 'gameover') {
        CTX.C.setVerdict({
          t: b.t,
          winner: b.winner === 'none' ? '' : b.winner,
          draw: b.winner === 'none'
        });
      }
    }
  }

  function seekTo(tick) { CTX.send('s:' + Math.max(0, Math.round(tick))); }

  function upgradeBeatButtons(s) {
    var host = byId('scrub');
    var placed = host.querySelectorAll('div.beat-marker');
    for (var i = 0; i < placed.length; i++) {
      (function (div) {
        var kind = '';
        div.classList.forEach(function (cls) {
          if (cls !== 'beat-marker' && !kind) kind = cls;
        });
        var tick = div.__tick;
        var button = document.createElement('button');
        button.type = 'button';
        button.className = div.className;
        button.style.left = div.style.left;
        button.__tick = tick;
        button.__kind = kind;
        var label = beatLabels[tick + '|' + kind] ||
          (kind + ' at tick ' + tick);
        button.title = label;
        button.setAttribute('aria-label', label);
        button.addEventListener('click', function (ev) {
          ev.stopPropagation();
          seekTo(tick);
        });
        div.parentNode.replaceChild(button, div);
      })(placed[i]);
    }
    applyBeatSpoilers(s);
  }

  function applyBeatSpoilers(s) {
    // The inherited spoiler gate holds the DIVs it placed; these buttons
    // replaced them, so the gate is re-applied here against the same rule.
    var show = CTX.C.getSpoilers();
    var buttons = byId('scrub').querySelectorAll('button.beat-marker');
    for (var i = 0; i < buttons.length; i++) {
      var hide = !show && buttons[i].__tick > s.t;
      buttons[i].style.display = hide ? 'none' : '';
    }
  }

  // ============================================================
  //  Endcard. The inherited #endcard is shown and hidden by the inherited
  //  chrome (state-driven off s.ph, so EVERY seek takes it down); this block
  //  writes what it says: the verdict in words, the role reveal table, and the
  //  line of counters. The starter's per-team stat panel has no counterpart
  //  here, so #ec-teams is emptied rather than left holding CTF columns.
  // ============================================================
  var endcardKey = '';
  function renderAgendaEndcard(s) {
    var over = s.over;
    if (!over) { endcardKey = ''; return; }
    var key = over.ending + '|' + over.deposits;
    if (key === endcardKey) return;
    endcardKey = key;
    var headline;
    switch (over.ending) {
      case 'crew_deposits':
        headline = 'CREW WIN \u2014 ' + over.deposits + ' DEPOSITS'; break;
      case 'impostor_ejected':
        headline = 'CREW WIN \u2014 THE IMPOSTOR WAS EJECTED'; break;
      case 'impostor_isolation':
        headline = 'IMPOSTOR WINS \u2014 ONE CREWMATE LEFT'; break;
      case 'timeout':
        headline = 'TIE \u2014 ' + (s.mt || s.mx) + ' TICKS, 0-0'; break;
      case 'deadline': headline = 'TIME'; break;
      case 'forfeit': headline = 'FORFEIT'; break;
      default: headline = String(over.ending || '').toUpperCase(); break;
    }
    byId('ec-headline').textContent = headline;
    byId('ec-wincond').textContent =
      'Crew win at ' + (over.depositTarget || 32) + ' deposits or by ' +
      'ejecting the impostor. The impostor wins at one crewmate left.';
    var roles = agenda(s).roles || [];
    var html = '';
    (s.roster || []).forEach(function (r, i) {
      var role = roles[i] || 'crew';
      html += '<div class="erow' + (role === 'impostor' ? ' imp' : '') +
        '" style="--tc:' + colourOfAlias(s, r.name) + '">' +
        '<span class="ealias">' + htmlEsc(r.name) + '</span>' +
        '<span class="erole">' + htmlEsc(role) + '</span>' +
        '<span class="epol">' + htmlEsc(r.pol || '') + '</span>' +
        '</div>';
    });
    byId('ec-roles').innerHTML = html;
    byId('ec-teams').innerHTML = '';
    byId('ec-how').textContent =
      over.freezes + ' freeze' + (over.freezes === 1 ? '' : 's') +
      ' \u00b7 ' + over.witnessed + ' witnessed \u00b7 ' +
      over.ejections + ' ejection' + (over.ejections === 1 ? '' : 's') +
      ' (' + (over.wrong ? over.wrong + ' wrong' : 'right') + ') \u00b7 ' +
      over.fake + ' fake deposits \u00b7 ' + over.meetings + ' meetings';
    byId('ec-replay').textContent = 'Press , to replay from the start.';
  }

  // ============================================================
  //  The three entry points the inherited script calls.
  // ============================================================
  window.AgendaChrome = {
    install: function (ctx) {
      CTX = ctx;
      buildCurtain();
    },
    frame: function (s, ctx, jumped) {
      CTX = ctx || CTX;
      buildAgendaBeats(s);
      renderSublines(s);
      renderCaption(s);
      renderRoster(s);
      renderVoteBoard(s);
      upgradeBeatButtons(s);
      renderAgendaEndcard(s);
    },
    event: function (e, s, ctx) {
      CTX = ctx || CTX;
      return applyAgendaEvent(e, s);
    }
  };

  // The same object under this game's full name, so a harness can drive the
  // block's builders directly against a synthetic worst-case frame.
  window.HiddenAgendaChrome = window.AgendaChrome;
})();
