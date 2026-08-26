'use strict';
// broadcast_core.js — the Hidden Agenda board renderer.
//
// Forked from coworld-ctf's broadcast_core.js: the module shape, the
// letterboxing/transform plumbing, the viewport handling, the pace stats and
// the page-facing API are the starter's and are untouched. What changed is the
// BOARD DRAW — paintbot ships rasterised sprite layers over its binary sprite
// protocol; Hidden Agenda's wasm module emits one compact JSON packet per frame
// and this file draws the station floor, walls, seams, grate, cogs, ice blocks
// and vision wedges from it.
//
// It runs inside the replay Worker on an OffscreenCanvas (and unchanged on a
// plain canvas, which is what tools/ci/renderer_fixture.html exercises), so it
// touches no DOM: the canvas draws the WORLD and the page's chrome draws the
// scorebug, vote board, roster strip, banner lane, feed, transport and endcard.
//
// One packet per frame out of the wasm module:
//   {"meta": {...}            // first packet only
//    "b": {t, c:[x,y,facing,state,carry,mine] x5, v:[5], g:[6], d, ph},
//    "hud": { the chrome state frame, handed to the page through onText }}

(function (scope) {
  var TEAM_TINT = {
    red: '#e0523a', blue: '#3f7cc4', green: '#45a85e',
    yellow: '#ddc531', pink: '#d96ab0'
  };
  var FACINGS = [[0, -1], [1, 0], [0, 1], [-1, 0]];
  var ST_ACTIVE = 0, ST_MINING = 1, ST_DEPOSIT = 2, ST_FROZEN = 3,
      ST_EJECTED = 4, ST_MEETING = 5;
  var FREEZE_FX_FRAMES = 12;
  var WITNESS_FX_FRAMES = 24;
  var ART_BASE = './art/';

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  // Art is OPTIONAL. Every sprite has a procedural fallback drawn in the same
  // box, so a missing or slow PNG degrades the look and never the frame: the
  // renderer must draw on its first call, before any fetch resolves.
  var art = {};
  function loadArt(name) {
    if (art[name] !== undefined) return;
    art[name] = null;
    try {
      fetch(ART_BASE + name + '.png', { credentials: 'omit' })
        .then(function (r) { return r.ok ? r.blob() : null; })
        .then(function (b) { return b ? createImageBitmap(b) : null; })
        .then(function (bmp) { if (bmp) art[name] = bmp; })
        .catch(function () {});
    } catch (ignore) {}
  }

  function create(config) {
    var canvas = config.canvas;
    var ctx = canvas.getContext('2d', { alpha: false });
    var onText = config.onText || function () {};
    var onStatus = config.onStatus || function () {};
    var onFirstFrame = config.onFirstFrame || function () {};
    var onTransform = config.onTransform || function () {};
    var onSendPacket = config.onSendPacket || null;

    var meta = null;
    var grid = null;
    var frame = null;
    var hud = null;
    var draws = 0;
    var firstFrameSent = false;
    var fx = [];
    var minimap = null, minimapCtx = null;
    var viewport = {
      w: config.viewportWidth || 960,
      h: config.viewportHeight || 540,
      dpr: config.devicePixelRatio || 1
    };
    var cell = 40, cols = 27, rows = 19;

    function worldW() { return cols * cell; }
    function worldH() { return rows * cell; }

    // ---- letterbox transform (the starter's shape, fit-only: the board is a
    // fixed 1080x760 and always fits the frame, so there is nothing to pan to)
    function transform() {
      var fit = Math.min(viewport.w / worldW(), viewport.h / worldH());
      return {
        scale: fit, fitScale: fit, zoom: 1, minZoom: 1, maxZoom: 1,
        offsetX: (viewport.w - worldW() * fit) / 2,
        offsetY: (viewport.h - worldH() * fit) / 2,
        nativeW: worldW(), nativeH: worldH(),
        focusX: worldW() / 2, focusY: worldH() / 2,
        visW: worldW(), visH: worldH()
      };
    }
    function reportTransform() { onTransform(transform()); }

    function setViewportSize(w, h, dpr) {
      viewport.w = Math.max(1, w || viewport.w);
      viewport.h = Math.max(1, h || viewport.h);
      viewport.dpr = dpr || viewport.dpr;
      canvas.width = Math.round(viewport.w * viewport.dpr);
      canvas.height = Math.round(viewport.h * viewport.dpr);
      reportTransform();
      draw();
    }

    // ---- packet ingest ----------------------------------------------------
    var decoder = new TextDecoder('utf-8');
    function ingest(bytes) {
      var text = (typeof bytes === 'string') ? bytes : decoder.decode(bytes);
      var packet = JSON.parse(text);
      if (packet.meta) applyMeta(packet.meta);
      if (packet.b) frame = packet.b;
      if (packet.hud) {
        hud = packet.hud;
        collectFx(hud.events);
        onText(JSON.stringify(hud));
      }
      draw();
      if (!firstFrameSent) { firstFrameSent = true; onFirstFrame(); }
    }

    function applyMeta(next) {
      meta = next;
      var cfg = meta.config || {};
      cols = cfg.cols || 27;
      rows = cfg.rows || 19;
      cell = cfg.cell || meta.cell || 40;
      grid = cfg.grid || null;
      (meta.colors || []).forEach(function (colour) {
        loadArt('cog_' + colour + '_front');
        loadArt('cog_' + colour + '_walk');
        loadArt('cog_' + colour + '_mine');
        loadArt('cog_' + colour + '_carry');
        loadArt('frozen_' + colour);
      });
      loadArt('floor_hub');
      loadArt('floor_vault');
      loadArt('floor_gallery');
      loadArt('floor_corridor');
      loadArt('wall');
      loadArt('wall_pillar');
      loadArt('seam_0');
      loadArt('seam_1');
      loadArt('seam_2');
      loadArt('seam_3');
      loadArt('grate_lit');
      loadArt('grate_dim');
      loadArt('gem');
      reportTransform();
    }

    function collectFx(events) {
      if (!events || !events.length) return;
      for (var i = 0; i < events.length; i++) {
        var e = events[i];
        if (e.k === 'freeze') {
          fx.push({ kind: 'beam', life: FREEZE_FX_FRAMES, seat: e.seat,
                    cell: e.cell });
        } else if (e.k === 'witness') {
          fx.push({ kind: 'wedge', life: WITNESS_FX_FRAMES,
                    alias: e.witness });
        }
      }
      if (fx.length > 24) fx = fx.slice(fx.length - 24);
    }

    // ---- board ------------------------------------------------------------
    function tileAt(x, y) {
      if (!grid || y < 0 || y >= grid.length) return '#';
      var row = grid[y];
      if (!row || x < 0 || x >= row.length) return '#';
      return row[x];
    }

    function roomTintAt(x, y) {
      var rooms = (meta && meta.config && meta.config.rooms) || [];
      for (var i = 0; i < rooms.length; i++) {
        var r = rooms[i];
        if (x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1) {
          if (r.id === 'HUB') return '#3a3128';
          if (r.id === 'N' || r.id === 'S') return '#332b23';
          return '#2e2720';
        }
      }
      return '#282119';
    }

    function floorArtAt(x, y) {
      var rooms = (meta && meta.config && meta.config.rooms) || [];
      for (var i = 0; i < rooms.length; i++) {
        var r = rooms[i];
        if (x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1) {
          if (r.id === 'HUB') return 'floor_hub';
          if (r.id === 'N' || r.id === 'S') return 'floor_gallery';
          return 'floor_vault';
        }
      }
      return 'floor_corridor';
    }

    function drawFloor() {
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < cols; x++) {
          var t = tileAt(x, y);
          var px = x * cell, py = y * cell;
          if (t === '#') {
            if (art.wall) { ctx.drawImage(art.wall, px, py, cell, cell); continue; }
            ctx.fillStyle = '#17120d';
            ctx.fillRect(px, py, cell, cell);
            ctx.fillStyle = 'rgba(242,232,216,0.055)';
            ctx.fillRect(px + 2, py + 2, cell - 4, 3);
            // rivets
            ctx.fillStyle = 'rgba(242,232,216,0.10)';
            ctx.fillRect(px + 5, py + cell - 8, 3, 3);
            ctx.fillRect(px + cell - 8, py + cell - 8, 3, 3);
            continue;
          }
          var tile = art[floorArtAt(x, y)];
          if (tile) { ctx.drawImage(tile, px, py, cell, cell); continue; }
          ctx.fillStyle = roomTintAt(x, y);
          ctx.fillRect(px, py, cell, cell);
          ctx.strokeStyle = 'rgba(242,232,216,0.045)';
          ctx.lineWidth = 1;
          ctx.strokeRect(px + 0.5, py + 0.5, cell - 1, cell - 1);
        }
      }
    }

    function drawGrate() {
      var cells = (meta && meta.config && meta.config.grate) || [];
      var deposits = frame ? frame.d : 0;
      var target = (hud && hud.agenda && hud.agenda.tgt) || 32;
      var lit = deposits > 0;
      for (var i = 0; i < cells.length; i++) {
        var px = cells[i][0] * cell, py = cells[i][1] * cell;
        var plate = lit ? art.grate_lit : art.grate_dim;
        if (plate) { ctx.drawImage(plate, px, py, cell, cell); continue; }
        ctx.fillStyle = lit ? '#4a3c26' : '#3a3020';
        ctx.fillRect(px, py, cell, cell);
        ctx.strokeStyle = 'rgba(232,163,61,0.55)';
        ctx.lineWidth = 2;
        for (var b = 6; b < cell - 4; b += 8) {
          ctx.beginPath();
          ctx.moveTo(px + 4, py + b);
          ctx.lineTo(px + cell - 4, py + b);
          ctx.stroke();
        }
      }
      if (!cells.length) return;
      // The counter etched beside the plate.
      var gx = cells[0][0] * cell, gy = cells[0][1] * cell;
      ctx.fillStyle = '#f2e8d8';
      ctx.font = '700 ' + Math.round(cell * 0.42) + 'px "Courier New", monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      ctx.fillText(deposits + ' / ' + target, gx + cell * 1.5, gy - 4);
    }

    function drawSeams() {
      var seams = (meta && meta.config && meta.config.seams) || [];
      var gems = (frame && frame.g) || [];
      for (var i = 0; i < seams.length; i++) {
        var px = seams[i].cell[0] * cell, py = seams[i].cell[1] * cell;
        var count = gems[i] === undefined ? 0 : gems[i];
        var ore = art['seam_' + Math.max(0, Math.min(3, count))];
        if (ore) {
          ctx.drawImage(ore, px, py, cell, cell);
          ctx.fillStyle = 'rgba(242,232,216,0.85)';
          ctx.font = '700 ' + Math.round(cell * 0.28) +
            'px "Courier New", monospace';
          ctx.textAlign = 'center';
          ctx.textBaseline = 'top';
          ctx.fillText(seams[i].id, px + cell / 2, py + 3);
          continue;
        }
        ctx.fillStyle = count > 0 ? '#3b4a52' : '#2a3238';
        ctx.fillRect(px, py, cell, cell);
        ctx.strokeStyle = 'rgba(140,200,220,0.35)';
        ctx.lineWidth = 1;
        ctx.strokeRect(px + 1.5, py + 1.5, cell - 3, cell - 3);
        for (var g = 0; g < count; g++) {
          ctx.fillStyle = '#8fe3f0';
          ctx.beginPath();
          ctx.arc(px + cell * 0.28 + g * cell * 0.22, py + cell * 0.66,
            cell * 0.09, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.fillStyle = 'rgba(242,232,216,0.85)';
        ctx.font = '700 ' + Math.round(cell * 0.28) + 'px "Courier New", monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'top';
        ctx.fillText(seams[i].id, px + cell / 2, py + 3);
      }
    }

    function wedgePath(cx, cy, facing, radius, colour, alpha) {
      var d = FACINGS[facing] || FACINGS[0];
      var base = Math.atan2(d[1], d[0]);
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.fillStyle = colour;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.arc(cx, cy, radius, base - Math.PI / 4, base + Math.PI / 4);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    }

    function drawWedges() {
      if (!frame || !meta) return;
      var radius = ((meta.config && meta.config.visionRadius) || 8) * cell;
      var impostor = (hud && hud.agenda) ? hud.agenda.imp : -1;
      var seats = frame.c.length / 6;
      for (var s = 0; s < seats; s++) {
        var st = frame.c[s * 6 + 3];
        if (st === ST_FROZEN || st === ST_EJECTED) continue;
        var cx = frame.c[s * 6] * cell + cell / 2;
        var cy = frame.c[s * 6 + 1] * cell + cell / 2;
        var facing = frame.c[s * 6 + 2];
        if (s === impostor) wedgePath(cx, cy, facing, radius, '#e0523a', 0.10);
      }
      // A witness's cone flashes white so the audience sees WHY the meeting
      // fired.
      for (var i = 0; i < fx.length; i++) {
        if (fx[i].kind !== 'wedge' || fx[i].life <= 0) continue;
        var slot = (meta.aliases || []).indexOf(fx[i].alias);
        if (slot < 0) continue;
        var wx = frame.c[slot * 6] * cell + cell / 2;
        var wy = frame.c[slot * 6 + 1] * cell + cell / 2;
        wedgePath(wx, wy, frame.c[slot * 6 + 2], radius, '#f2e8d8',
          0.10 + 0.14 * (fx[i].life / WITNESS_FX_FRAMES));
      }
    }

    function drawCogBody(slot, colour, st, carry, mineProgress, px, py) {
      var key = st === ST_FROZEN ? 'frozen_' + colour
        : (carry > 0 ? 'cog_' + colour + '_carry'
          : (st === ST_MINING ? 'cog_' + colour + '_mine'
            : 'cog_' + colour + '_front'));
      var bmp = art[key] || art['cog_' + colour + '_front'];
      var size = cell * 0.78;
      if (bmp) {
        ctx.drawImage(bmp, px - size / 2, py - size * 0.92, size, size);
      } else {
        // Procedural fallback: a wheeled chassis with a screen face, drawn in
        // exactly the same box so the layout never shifts.
        ctx.fillStyle = st === ST_FROZEN ? '#9fd8ea' : (TEAM_TINT[colour] || '#888');
        ctx.beginPath();
        ctx.arc(px, py - size * 0.42, size * 0.34, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = 'rgba(20,14,9,0.75)';
        ctx.fillRect(px - size * 0.20, py - size * 0.55, size * 0.40,
          size * 0.20);
        ctx.fillStyle = '#8fe3f0';
        ctx.fillRect(px - size * 0.14, py - size * 0.50, size * 0.28,
          size * 0.07);
        ctx.fillStyle = 'rgba(20,14,9,0.8)';
        ctx.beginPath();
        ctx.arc(px, py - size * 0.06, size * 0.16, 0, Math.PI * 2);
        ctx.fill();
      }
      if (st === ST_FROZEN) {
        ctx.save();
        ctx.globalAlpha = 0.55;
        ctx.fillStyle = '#bfe9f7';
        ctx.fillRect(px - size * 0.42, py - size * 0.98, size * 0.84,
          size * 1.02);
        ctx.strokeStyle = '#eafaff';
        ctx.lineWidth = 2;
        ctx.strokeRect(px - size * 0.42, py - size * 0.98, size * 0.84,
          size * 1.02);
        ctx.restore();
      }
      if (st === ST_MINING && mineProgress > 0) {
        var span = ((meta.config && meta.config.mineTicks) || 72);
        ctx.strokeStyle = '#e8a33d';
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.arc(px, py - size * 0.42, size * 0.46, -Math.PI / 2,
          -Math.PI / 2 + Math.PI * 2 * clamp(mineProgress / span, 0, 1));
        ctx.stroke();
      }
      for (var g = 0; g < carry; g++) {
        ctx.fillStyle = '#8fe3f0';
        ctx.beginPath();
        ctx.arc(px - size * 0.16 + g * size * 0.32, py - size * 1.06,
          size * 0.10, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    function drawCogs() {
      if (!frame || !meta) return;
      var seats = frame.c.length / 6;
      var showLabels = cell >= 18;
      for (var s = 0; s < seats; s++) {
        var st = frame.c[s * 6 + 3];
        if (st === ST_EJECTED) continue;
        var colour = (meta.colors && meta.colors[s]) || 'red';
        var px = frame.c[s * 6] * cell + cell / 2;
        var py = frame.c[s * 6 + 1] * cell + cell * 0.92;
        // Ground ellipse under the wheels carries the body colour, so the kit
        // on the sprite stays readable (art-nanobanana.md step 3).
        ctx.save();
        ctx.globalAlpha = 0.55;
        ctx.fillStyle = TEAM_TINT[colour] || '#888';
        ctx.beginPath();
        ctx.ellipse(px, py, cell * 0.30, cell * 0.13, 0, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
        drawCogBody(s, colour, st, frame.c[s * 6 + 4], frame.c[s * 6 + 5],
          px, py);
        if (showLabels) {
          var label = (meta.aliases && meta.aliases[s]) || ('#' + s);
          ctx.font = '700 ' + Math.round(cell * 0.26) +
            'px "Courier New", monospace';
          ctx.textAlign = 'center';
          ctx.textBaseline = 'top';
          ctx.fillStyle = 'rgba(20,14,9,0.75)';
          var w = ctx.measureText(label).width + 6;
          ctx.fillRect(px - w / 2, py + 2, w, cell * 0.30);
          ctx.fillStyle = TEAM_TINT[colour] || '#f2e8d8';
          ctx.fillText(label, px, py + 4);
        }
      }
    }

    function drawFx() {
      if (!frame) return;
      for (var i = 0; i < fx.length; i++) {
        var f = fx[i];
        if (f.kind !== 'beam' || f.life <= 0) continue;
        var s = f.seat;
        if (s === undefined || s < 0) continue;
        var ax = frame.c[s * 6] * cell + cell / 2;
        var ay = frame.c[s * 6 + 1] * cell + cell / 2;
        var bx = f.cell[0] * cell + cell / 2;
        var by = f.cell[1] * cell + cell / 2;
        ctx.save();
        ctx.globalAlpha = clamp(f.life / FREEZE_FX_FRAMES, 0, 1);
        ctx.strokeStyle = '#bfe9f7';
        ctx.lineWidth = 5;
        ctx.beginPath();
        ctx.moveTo(ax, ay);
        ctx.lineTo(bx, by);
        ctx.stroke();
        ctx.fillStyle = '#eafaff';
        ctx.beginPath();
        ctx.arc(bx, by, cell * 0.45 * (1 - f.life / FREEZE_FX_FRAMES) + 4,
          0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
      for (var j = fx.length - 1; j >= 0; j--) {
        fx[j].life -= 1;
        if (fx[j].life <= 0) fx.splice(j, 1);
      }
    }

    function drawMinimap() {
      if (!minimapCtx || !frame) return;
      var w = minimap.width, h = minimap.height;
      minimapCtx.fillStyle = '#17120d';
      minimapCtx.fillRect(0, 0, w, h);
      var sx = w / cols, sy = h / rows;
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < cols; x++) {
          if (tileAt(x, y) === '#') continue;
          minimapCtx.fillStyle = '#2e2720';
          minimapCtx.fillRect(x * sx, y * sy, sx, sy);
        }
      }
      var seats = frame.c.length / 6;
      for (var s = 0; s < seats; s++) {
        if (frame.c[s * 6 + 3] === ST_EJECTED) continue;
        minimapCtx.fillStyle =
          TEAM_TINT[(meta.colors && meta.colors[s]) || 'red'];
        minimapCtx.fillRect(frame.c[s * 6] * sx, frame.c[s * 6 + 1] * sy,
          Math.max(2, sx), Math.max(2, sy));
      }
    }

    function draw() {
      var t = transform();
      ctx.setTransform(viewport.dpr, 0, 0, viewport.dpr, 0, 0);
      ctx.fillStyle = '#16110d';
      ctx.fillRect(0, 0, viewport.w, viewport.h);
      if (!meta || !frame) { draws++; return; }
      ctx.save();
      ctx.translate(t.offsetX, t.offsetY);
      ctx.scale(t.scale, t.scale);
      drawFloor();
      drawSeams();
      drawGrate();
      drawWedges();
      drawFx();
      drawCogs();
      ctx.restore();
      drawMinimap();
      draws++;
    }

    var encoder = new TextEncoder();
    function sendCommand(text) {
      if (onSendPacket) onSendPacket(encoder.encode(String(text || '')));
    }

    return {
      start: function () {
        onStatus('open');
        setViewportSize(viewport.w, viewport.h, viewport.dpr);
      },
      stop: function () { fx = []; },
      ingest: ingest,
      draw: draw,
      sendCommand: sendCommand,
      clickMap: function () { /* the board has no click targets */ },
      setViewportSize: setViewportSize,
      attachMinimap: function (surface) {
        minimap = surface || null;
        minimapCtx = surface ? surface.getContext('2d') : null;
      },
      zoomAt: function () { reportTransform(); },
      setZoom: function () { reportTransform(); },
      panBy: function () {},
      panByMap: function () {},
      panTo: function () {},
      resetView: function () { reportTransform(); },
      getTransform: transform,
      setViewportFit: function () { reportTransform(); draw(); },
      getPaceStats: function () {
        return { enabled: false, queued: 0, presented: draws,
                 interval: 1000 / 24, draws: draws };
      }
    };
  }

  scope.BroadcastCore = { create: create };
})(typeof self !== 'undefined' ? self : this);
