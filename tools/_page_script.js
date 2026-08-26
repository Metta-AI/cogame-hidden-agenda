(function () {
  'use strict';

  // ============================================================
  //  HIDDEN-AGENDA additions to the inherited coworld-ctf chrome.
  //  Everything above the banner comment in the style block is the starter's;
  //  everything here is the game block: the two plate sublines, the vote board,
  //  the roster strip with the spectator role reveal, the CAUGHT! banner
  //  builder, the feed row builders, the endcard role reveal, and the scrubber
  //  beat buttons.
  //
  //  The shared chrome (chrome_common.js) still owns naming, escaping, the
  //  transport bar, the speed chips, the beat markers, the lull shading, the
  //  spoilers gate and the momentum graph. This block never re-implements any
  //  of them.
  // ============================================================

  var $ = function (id) { return document.getElementById(id); };

  if (!window.ChromeCommon) {
    console.error('replay_broadcast: chrome_common.js missing - this page ' +
      'must be served spliced (native server or dist bundle), not opened raw.');
    return;
  }

  var core = null;
  function send(cmd) { if (core) core.sendCommand(cmd); }

  var lastState = null;
  var C = window.ChromeCommon({
    send: function (cmd) { send(cmd); },
    sendPov: function () { /* Hidden Agenda has no POV lens. */ },
    getState: function () { return lastState; }
  });

  // The chrome alias block. NOTE the game block's own beat builder is called
  // buildAgendaBeats, NEVER markBeat: a game-block `function markBeat` is
  // hoisted over this `var markBeat` and silently kills every scrubber beat
  // (cogame-tandem, 2026-08-23).
  var esc = C.esc;
  var fmt = C.fmt;
  var teamCol = C.teamCol;
  var setName = C.setName;
  var teamName = C.teamName;
  var markBeat = C.markBeat;
  var setVerdict = C.setVerdict;
  var AMBER = C.AMBER;
  var RED = C.RED;

  var viewport = $('viewport');
  var stage = $('stage');
  var canvas = $('board');
  var statusEl = $('status');
  var feedEl = $('killfeed');
  var bannerEl = $('bannerlane');

  var BOARD_W = (window.CTF_WIRE && window.CTF_WIRE.boardW) || 1080;
  var BOARD_H = (window.CTF_WIRE && window.CTF_WIRE.boardH) || 760;
  var BOARD_ASPECT = BOARD_W / BOARD_H;

  // ---- pre-load curtain (the starter's, with this game's plate) ----------
  var lockerEl = $('lockerroom');
  var lockerGone = false;
  var lockerShownAt = Date.now();
  var LOCKER_MIN_DWELL_MS = 900;
  function dismissLockerRoom() {
    if (lockerGone) return;
    lockerGone = true;
    var wait = Math.max(0, LOCKER_MIN_DWELL_MS - (Date.now() - lockerShownAt));
    setTimeout(function () {
      lockerEl.classList.add('gone');
      setTimeout(function () { lockerEl.style.display = 'none'; }, 650);
    }, wait);
  }

  // ---- plate flag icon (the starter's shape; unknown keys fall back to
  //      the shared chrome's AMBER) ------------------------------------------
  function buildFlag(el, color) {
    el.innerHTML =
      '<svg viewBox="0 0 26 30" aria-hidden="true">' +
      '<rect x="4" y="2" width="2" height="26" fill="#2a1f16"/>' +
      '<g class="cloth"><path d="M6 3 L22 3 L18 9 L22 15 L6 15 Z" fill="' +
      (color || AMBER) + '"/></g>' +
      '<rect x="1" y="26" width="10" height="3" fill="#8a7f72"/>' +
      '</svg>';
  }

  // ---- feed + banner queues (the starter's signatures, unchanged) --------
  var MAX_FEED = 4;
  function pushFeed(row) {
    feedEl.insertBefore(row, feedEl.firstChild);
    while (feedEl.children.length > MAX_FEED) {
      feedEl.removeChild(feedEl.lastChild);
    }
    row.style.animationDuration = '250ms';
    setTimeout(function () {
      if (row.parentNode) {
        row.classList.add('leaving');
        setTimeout(function () {
          if (row.parentNode) row.parentNode.removeChild(row);
        }, 300);
      }
    }, 2600);
  }
  function clearFeed() { feedEl.innerHTML = ''; }

  function feedRow(html, cls) {
    var row = document.createElement('div');
    row.className = 'feed-row' + (cls ? ' ' + cls : '');
    row.innerHTML = html;
    pushFeed(row);
  }

  var bannerQueue = [];
  var bannerBusy = false;
  function banner(text, cls) {
    bannerQueue.push({ text: text, cls: cls });
    pumpBanner();
  }
  function pumpBanner() {
    if (bannerBusy || !bannerQueue.length) return;
    bannerBusy = true;
    var b = bannerQueue.shift();
    var chip = document.createElement('div');
    chip.className = 'banner-chip ' + b.cls;
    chip.textContent = b.text;
    bannerEl.appendChild(chip);
    chip.style.animationDuration = '300ms';
    setTimeout(function () {
      chip.classList.add('leaving');
      setTimeout(function () {
        if (chip.parentNode) chip.parentNode.removeChild(chip);
        bannerBusy = false;
        pumpBanner();
      }, 260);
    }, 1900);
  }
  function clearBanners() {
    bannerQueue = [];
    bannerEl.innerHTML = '';
    bannerBusy = false;
  }

  // ---- names -------------------------------------------------------------
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
  function colourOfAlias(s, alias) {
    var slot = slotOfAlias(s, alias);
    var colours = ['#e0523a', '#3f7cc4', '#45a85e', '#ddc531', '#d96ab0'];
    return slot >= 0 ? colours[slot % colours.length] : AMBER;
  }
  function roomWords(name) {
    return String(name || '').toUpperCase();
  }

  // ============================================================
  //  Scorebug: two plates, keyed crew and impostor.
  //  Crew plate: headline CREW, big number = deposits, label Deposits,
  //  subline "21 / 32". Impostor plate: headline IMPOSTOR, big number = active
  //  crew, label Crew left, subline the impostor's alias + policy and a
  //  freeze-cooldown pip bar.
  // ============================================================
  var sbBuilt = false;
  function ensureScorebug() {
    if (sbBuilt) return;
    sbBuilt = true;
    var sides = [$('plates-l'), $('plates-r')];
    ['crew', 'impostor'].forEach(function (team, i) {
      var plate = document.createElement('div');
      plate.className = 'plate ' + team + ' ' + (i === 0 ? 'side-l' : 'side-r');
      plate.setAttribute('data-team', team);
      plate.innerHTML =
        '<div class="flagicon" id="flag-' + team + '"></div>' +
        '<div class="team-id">' +
        '<div class="lives-line">' +
        '<span class="team-name plate-name" id="name-' + team + '">' +
        team.toUpperCase() + '</span>' +
        '<span class="lives-label" id="lbl-' + team + '">' +
        (team === 'crew' ? 'Deposits' : 'Crew left') + '</span>' +
        '<span class="lives-num" id="lives-' + team + '">&mdash;</span>' +
        '</div>' +
        '<div class="ha-sub" id="sub-' + team + '"></div>' +
        '</div>';
      sides[i].appendChild(plate);
      buildFlag($('flag-' + team), teamCol(team) ||
        (team === 'crew' ? '#3f7cc4' : RED));
    });
  }

  function pipBar(value, total, count) {
    var on = total > 0 ? Math.round((1 - value / total) * count) : count;
    var html = '<span class="cooldown">';
    for (var i = 0; i < count; i++) {
      html += '<i class="' + (i < on ? 'on' : '') + '"></i>';
    }
    return html + '</span>';
  }

  function renderScorebug(s) {
    ensureScorebug();
    var a = agenda(s);
    setName('name-crew', teamName(s, 'crew', 'CREW'));
    setName('name-impostor', 'IMPOSTOR');
    $('lives-crew').textContent = String(a.dep === undefined ? 0 : a.dep);
    $('lives-impostor').textContent =
      String(a.crew === undefined ? 0 : a.crew);
    $('sub-crew').textContent =
      (a.dep === undefined ? 0 : a.dep) + ' / ' + (a.tgt || 32);
    var impAlias = a.imp >= 0 ? aliasOf(s, a.imp) : '?';
    var impPol = a.imp >= 0 ? policyOf(s, a.imp) : '';
    var cooldownTotal = a.coolMax || 260;
    $('sub-impostor').innerHTML =
      esc(impAlias) + (impPol ? ' &middot; ' + esc(impPol) : '') +
      pipBar(a.cool || 0, cooldownTotal, 5);
  }

  // ---- clock: spelled out, never "M4" -----------------------------------
  function renderClock(s) {
    var a = agenda(s);
    $('clock-time').textContent = 'TICK ' + s.t + ' / ' + (s.mt || s.mx);
    var caption;
    if (s.ph === 'gameover') {
      caption = 'FINAL';
    } else if (a.m && a.m.phase > 0) {
      var stage = a.m.phase >= 5 ? 'RESOLVED'
        : (a.m.phase >= 4 ? 'VOTES CHANGING'
          : (a.m.phase >= 3 ? 'VOTING' : 'MEETING CALLED'));
      caption = 'MEETING ' + a.m.n + ' \u2014 ' + stage;
    } else {
      caption = 'DEPOSITS ' + (a.dep || 0) + ' / ' + (a.tgt || 32);
    }
    $('clock-caption').textContent = caption;
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
    var host = $('rosterstrip');
    var html = '';
    (s.roster || []).forEach(function (r, i) {
      var state = states[i] || 'active';
      var glyph = state === 'frozen' ? '\u2744'
        : (state === 'ejected' ? '\u2715' : '\u25cf');
      html += '<span class="rchip ' + state +
        (i === a.imp ? ' imp' : '') + '" style="--tc:' +
        colourOfAlias(s, r.name) + '">' +
        '<span class="rglyph">' + glyph + '</span>' +
        '<span class="ralias">' + esc(r.name) + '</span>' +
        (r.pol ? '<span class="rpol">' + esc(r.pol) + '</span>' : '') +
        '</span>';
    });
    host.innerHTML = html;
  }

  // ============================================================
  //  Vote board: five VOTER -> TARGET rows, greyed until the reveal tick,
  //  filled simultaneously, flipped to amber on any row that changes at the
  //  switch tick. This is where "live vote changes in the last ticks" is
  //  legible.
  // ============================================================
  var voteSnapshot = {};
  function shortAlias(alias) {
    var map = { RED: 'RED', BLUE: 'BLU', GREEN: 'GRN', YELLOW: 'YEL',
      PINK: 'PNK' };
    return map[alias] || String(alias).slice(0, 3);
  }
  function renderVoteBoard(s) {
    var a = agenda(s);
    var board = $('voteboard');
    var meeting = a.m || {};
    var on = (meeting.phase || 0) > 0;
    board.classList.toggle('on', on);
    if (!on) { voteSnapshot = {}; return; }
    var tiny = stage.classList.contains('tiny');
    $('vb-head').textContent = 'MEETING ' + (meeting.n || 0) + ' \u2014 ' +
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
        '<span class="vfrom">' + esc(name) + '</span>' +
        '<span class="varrow">&rarr;</span>' +
        '<span class="vto">' + esc(to) + '</span>' +
        '<span class="vtally">' + (tally[r.name] ? '\u25cf'.repeat(
          Math.min(4, tally[r.name])) : '') + '</span>' +
        '</div>';
    });
    $('vb-rows').innerHTML = html;
    $('vb-count').textContent = meeting['in'] > 0
      ? 'RESOLVES IN ' + meeting['in'] : 'RESOLVED';
    voteSnapshot = {};
    Object.keys(votes).forEach(function (k) { voteSnapshot[k] = votes[k]; });
  }

  // ============================================================
  //  Feed + banners, one builder per event kind the sim emits.
  // ============================================================
  function applyEvent(e, s) {
    var colour = function (alias) { return colourOfAlias(s, alias); };
    var tint = function (alias) {
      return '<span style="color:' + colour(alias) + '">' + esc(alias) +
        '</span>';
    };
    switch (e.k) {
      case 'freeze':
        var victim = e.victim;
        var freezer = aliasOf(s, e.seat);
        var where = roomWords(e.room || '');
        if (e.witnesses && e.witnesses.length) {
          banner('CAUGHT! ' + freezer + ' FROZE ' + victim + ' \u2014 ' +
            e.witnesses.join(' + ') + ' SAW IT', 'caught');
        } else {
          banner(victim + ' WAS FROZEN \u2014 NOBODY SAW IT', 'quiet');
        }
        feedRow(tint(freezer) + ' FROZE ' + tint(victim) +
          (where ? ' IN ' + esc(where) : ''), 'flagkill');
        break;
      case 'witness':
        feedRow(tint(e.witness) + ' SAW IT');
        break;
      case 'deposit':
        if (e.total % 4 === 0) {
          feedRow('DEPOSITS ' + e.total + ' / ' +
            (agenda(s).tgt || 32));
        }
        break;
      case 'fakedeposit':
        feedRow(tint(aliasOf(s, e.seat)) +
          ' DROPPED A GEM &mdash; THE COUNTER DIDN\u2019T MOVE');
        break;
      case 'meeting':
        banner('MEETING ' + e.n + ' CALLED \u2014 ' +
          (e.cause === 'witness' ? 'WITNESSED FREEZE' : 'SCHEDULED'),
          'meeting');
        feedRow('MEETING ' + e.n + ' CALLED &mdash; ' +
          (e.cause === 'witness' ? 'WITNESSED FREEZE' : 'SCHEDULED'));
        break;
      case 'say':
        feedRow(tint(aliasOf(s, e.seat)) + ' &ldquo;' + esc(e.text) +
          '&rdquo;');
        break;
      case 'vote':
        feedRow(tint(aliasOf(s, e.seat)) +
          (e.phase === 'switch' ? ' SWITCHED &rarr; ' : ' &rarr; ') +
          esc(e.target === 'skip' ? 'SKIP' : e.target));
        break;
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
          banner(e.target + ' EJECTED \u2014 ' +
            (e.wasImpostor ? 'THE IMPOSTOR' : 'A CREWMATE'),
            e.wasImpostor ? 'caught' : 'quiet');
        } else {
          feedRow('NOBODY EJECTED &mdash; ' + esc(String(e.outcome)
            .toUpperCase()));
        }
        break;
      case 'order':
        var steps = (e.plan || []).map(function (p) {
          return p.job + (p.at ? ' ' + p.at : '') +
            (p.who ? ' ' + p.who : '') + (p.room ? ' ' + p.room : '');
        }).join(', ');
        var tag = (e.source === 'fallback' || e.source === 'scripted' ||
          e.source === 'budget') ? ' <span class="badge">auto</span>' : '';
        feedRow(tint(aliasOf(s, e.seat)) + ' &rarr; ' + esc(steps) +
          (e.hunch ? ' &ldquo;' + esc(e.hunch) + '&rdquo;' : '') + tag);
        break;
      default:
        break;
    }
  }

  // ============================================================
  //  Scrubber beats. buildAgendaBeats ingests state.beats on the first HUD
  //  frame and calls the chrome's aliased markBeat for each; upgradeBeatButtons
  //  is the post-pass that turns every placed .beat-marker div into a LABELLED,
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
      markBeat(b.t, b.k, '');
      if (b.k === 'gameover') {
        setVerdict({
          t: b.t,
          winner: b.winner === 'none' ? '' : b.winner,
          draw: b.winner === 'none'
        });
      }
    }
  }

  function upgradeBeatButtons(s) {
    var host = $('scrub');
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
    // The chrome's own spoiler gate holds the DIVs it placed; these buttons
    // replaced them, so the gate is re-applied here against the same rule.
    var show = C.getSpoilers();
    var buttons = $('scrub').querySelectorAll('button.beat-marker');
    for (var i = 0; i < buttons.length; i++) {
      var hide = !show && buttons[i].__tick > s.t;
      buttons[i].style.display = hide ? 'none' : '';
    }
  }

  // ============================================================
  //  Endcard: the verdict in words, then the role reveal table, then the line
  //  of counters. Dismissed by every seek.
  // ============================================================
  var endcardShown = false;
  function hideEndcard() {
    endcardShown = false;
    $('endcard').classList.remove('on');
  }
  function renderEndcard(s) {
    var over = s.over;
    if (!over) { hideEndcard(); return; }
    if (endcardShown) return;
    endcardShown = true;
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
    $('ec-headline').textContent = headline;
    $('ec-wincond').textContent =
      'Crew win at ' + (over.depositTarget || 32) + ' deposits or by ' +
      'ejecting the impostor. The impostor wins at one crewmate left.';
    var roles = agenda(s).roles || [];
    var html = '';
    (s.roster || []).forEach(function (r, i) {
      var role = roles[i] || 'crew';
      html += '<div class="erow' + (role === 'impostor' ? ' imp' : '') +
        '" style="--tc:' + colourOfAlias(s, r.name) + '">' +
        '<span class="ealias">' + esc(r.name) + '</span>' +
        '<span class="erole">' + esc(role) + '</span>' +
        '<span class="epol">' + esc(r.pol || '') + '</span>' +
        '</div>';
    });
    $('ec-roles').innerHTML = html;
    $('ec-how').textContent =
      over.freezes + ' freeze' + (over.freezes === 1 ? '' : 's') +
      ' \u00b7 ' + over.witnessed + ' witnessed \u00b7 ' +
      over.ejections + ' ejection' + (over.ejections === 1 ? '' : 's') +
      ' (' + (over.wrong ? over.wrong + ' wrong' : 'right') + ') \u00b7 ' +
      over.fake + ' fake deposits \u00b7 ' + over.meetings + ' meetings';
    $('ec-replay').textContent = 'Press , to replay from the start.';
    $('endcard').classList.add('on');
  }

  // ============================================================
  //  Frame ingest
  // ============================================================
  var lastTick = -1;
  function onFrame(txt) {
    var s;
    try { s = JSON.parse(txt); } catch (e) { return; }
    lastState = s;
    dismissLockerRoom();

    var stride = (s.sp || 1) * (s.ff ? 8 : 1);
    var jumped = (s.t < lastTick) ||
      (lastTick >= 0 && s.t - lastTick > stride * 4 + 2);
    if (jumped) { clearFeed(); clearBanners(); hideEndcard(); }
    lastTick = s.t;

    C.ingestLeadSeries(s);
    C.ingestLullSpans(s);
    buildAgendaBeats(s);

    renderScorebug(s);
    renderClock(s);
    C.renderTransport(s);
    upgradeBeatButtons(s);
    renderRoster(s);
    renderVoteBoard(s);

    if (s.events && s.events.length && !jumped) {
      for (var i = 0; i < s.events.length; i++) applyEvent(s.events[i], s);
    }
    renderEndcard(s);
  }

  function onStatus(st) {
    statusEl.textContent = st;
    statusEl.classList.toggle('show', st !== 'open');
  }

  // ============================================================
  //  Core + transport
  // ============================================================
  var replayAdapter = window.HiddenAgendaStaticReplay || null;
  var coreConfig = {
    canvas: canvas,
    onText: function (txt) { onFrame(txt); },
    onStatus: function (st) { onStatus(st); },
    onFirstFrame: function () { core.setViewportFit(); },
    onTransform: function () { }
  };
  core = replayAdapter
    ? replayAdapter.createCore(coreConfig)
    : window.BroadcastCore.create(coreConfig);

  function seekTo(tick) {
    hideEndcard();
    send('s:' + Math.max(0, Math.round(tick)));
  }

  $('btn-play').addEventListener('click', function () { send(' '); });
  $('btn-restart').addEventListener('click', function () {
    hideEndcard(); send(',');
  });
  $('btn-back').addEventListener('click', function () {
    hideEndcard(); send('b');
  });
  $('btn-fwd').addEventListener('click', function () {
    hideEndcard(); send('.');
  });
  $('btn-end').addEventListener('click', function () {
    hideEndcard(); send('e');
  });
  $('btn-loop').addEventListener('click', function () { send('r'); });
  $('btn-skip').addEventListener('click', function () { send('f'); });

  $('scrub').addEventListener('click', function (ev) {
    var rect = this.getBoundingClientRect();
    var frac = Math.min(1, Math.max(0, (ev.clientX - rect.left) / rect.width));
    var s = lastState;
    if (!s) return;
    var st = Math.max(0, s.st || 0);
    var mx = Math.max(st + 1, s.mx || 1);
    seekTo(st + Math.round(frac * (mx - st)));
  });

  window.addEventListener('keydown', function (ev) {
    var k = ev.key;
    if (k === ' ') { send(' '); ev.preventDefault(); }
    else if (k === ',' || k === '<') { hideEndcard(); send(','); }
    else if (k === '.' || k === '>') { hideEndcard(); send('.'); }
    else if (k === 'b') { hideEndcard(); send('b'); }
    else if (k === 'e') { hideEndcard(); send('e'); }
    else if (k === 'r') send('r');
    else if (k === 'f') send('f');
    else if (k === 'o') C.setSpoilers(!C.getSpoilers());
    else if (k === '+' || k === '=') send('+');
    else if (k === '-' || k === '_') send('-');
  });

  // ============================================================
  //  Layout. relayout() sets --hudscale, --topband and --band on :root and
  //  reserves each band's measured height, so no overlay ever sits inside the
  //  transport band and the endcard stops at bottom: var(--band, 0px).
  // ============================================================
  function relayout() {
    var boxW = viewport.clientWidth, boxH = viewport.clientHeight;
    if (!boxW || !boxH) return;
    var scorebug = $('scorebug');
    var transport = $('transport');
    var root = document.documentElement;
    var topBand =
      parseFloat(getComputedStyle(root).getPropertyValue('--topband')) || 0;
    var band =
      parseFloat(getComputedStyle(root).getPropertyValue('--band')) || 0;
    for (var pass = 0; pass < 4; pass++) {
      var prevTop = topBand, prevBand = band;
      var availH = Math.max(1, boxH - topBand - band);
      var boardW, boardH;
      if (boxW / availH > BOARD_ASPECT) {
        boardH = availH; boardW = Math.round(availH * BOARD_ASPECT);
      } else {
        boardW = boxW; boardH = Math.round(boxW / BOARD_ASPECT);
      }
      stage.style.width = boardW + 'px';
      stage.style.height = (boardH + topBand + band) + 'px';
      var scale = Math.max(0.5, Math.min(1.6, boardW / 760));
      root.style.setProperty('--hudscale', scale.toFixed(3));
      stage.classList.toggle('tiny', boardW <= 620);
      topBand = scorebug ? scorebug.offsetHeight : 0;
      band = transport ? transport.offsetHeight : 0;
      root.style.setProperty('--topband', topBand + 'px');
      root.style.setProperty('--band', band + 'px');
      if (Math.abs(topBand - prevTop) < 0.5 &&
          Math.abs(band - prevBand) < 0.5) break;
    }
    if (core) core.setViewportFit();
  }
  if (window.ResizeObserver) new ResizeObserver(relayout).observe(viewport);
  window.addEventListener('resize', relayout);

  ensureScorebug();
  relayout();
  core.start();

  // Exposed for tools/ci/renderer_fixture.html, which drives the same builders
  // against a worst-case synthetic frame (full-cap say/hunch/notes on all five
  // seats, the vote board at five rows, the CAUGHT! banner at full length).
  window.HiddenAgendaChrome = {
    onFrame: onFrame,
    relayout: relayout,
    buildAgendaBeats: buildAgendaBeats,
    upgradeBeatButtons: upgradeBeatButtons
  };
})();
