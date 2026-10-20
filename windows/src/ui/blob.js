// Blob, drawn on a canvas — a port of the SwiftUI BlobCharacter so Blob looks the same on Windows.
// Moods: sleepy, idle, curious, listening, thinking, speaking, happy, asking, error.
'use strict';

const C = { cyan: '#00DBFF', light: '#B8FFFF', deep: '#007AB3', amber: '#FFB833', red: '#FF5966' };

function rgba(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

function blobPath(ctx, rx, ry, t, wobble) {
  const n = 10, pts = [];
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2 - Math.PI / 2;
    const w = 1 + wobble * Math.sin(t * (1.3 + (i % 3) * 0.45) + i * 1.7);
    let x = Math.cos(a), y = Math.sin(a);
    if (y > 0) { x *= 1 + 0.05 * y; y *= 0.96; }
    pts.push([x * rx * w, y * ry * w]);
  }
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
    ctx.bezierCurveTo(p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6, p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6, p2[0], p2[1]);
  }
  ctx.closePath();
}

function roundRect(ctx, x, y, w, h, r) {
  if (ctx.beginPath) ctx.beginPath();            // Path2D objects (used for the eyes) have no beginPath
  ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}

function blink(t) {
  const cyc = t % 4.3;
  if (cyc < 0.13) return Math.max(0.08, Math.abs(cyc - 0.065) / 0.065);
  if (Math.floor(t / 4.3) % 3 === 0 && cyc > 0.25 && cyc < 0.38) return Math.max(0.08, Math.abs(cyc - 0.315) / 0.065);
  return 1;
}

/** Draws one frame. size = Blob's body box (the canvas should be ~1.9× larger for the glow). */
function drawBlob(ctx, cx, cy, s, t, { mood = 'idle', level = 0, look = { x: 0, y: 0 } } = {}) {
  const tint = mood === 'error' ? C.red : mood === 'asking' ? C.amber : C.cyan;
  const glow = { sleepy: 0.22 + Math.sin(t * 0.9) * 0.06, idle: 0.45, curious: 0.7, listening: 0.8 + level * 0.6, thinking: 0.65 + Math.sin(t * 3.2) * 0.25,
                 speaking: 0.7 + level * 0.5, happy: 1, asking: 0.85, error: 0.8 }[mood] ?? 0.45;
  const energy = mood === 'listening' || mood === 'speaking' ? level : 0;
  const breathe = (mood === 'sleepy' ? 1 + Math.sin(t * 0.9) * 0.03 : 1 + Math.sin(t * 2) * 0.012) + energy * 0.08;
  const bob = mood === 'sleepy' ? 0 : Math.sin(t * 1.6) * s * 0.022 - (mood === 'happy' ? Math.abs(Math.sin(t * 7)) * s * 0.06 : 0);
  const tilt = { curious: look.x * 9, listening: -6 + Math.sin(t * 1.5) * 2, thinking: Math.sin(t * 0.8) * 5, asking: 8, error: Math.sin(t * 30) * 2.5, sleepy: -10 }[mood] ?? 0;

  // Halo
  const g = Math.min(glow, 1.2);
  const halo = ctx.createRadialGradient(cx, cy, s * 0.18, cx, cy, s * 0.95);
  halo.addColorStop(0, rgba(tint, 0.55 * g)); halo.addColorStop(0.45, rgba(tint, 0.16 * g)); halo.addColorStop(1, rgba(tint, 0));
  ctx.fillStyle = halo;
  ctx.beginPath(); ctx.arc(cx, cy, s * 0.95, 0, Math.PI * 2); ctx.fill();

  ctx.save();
  ctx.translate(cx, cy + bob);
  ctx.rotate((tilt * Math.PI) / 180);
  ctx.scale(breathe, breathe);

  // Arms (behind the body)
  for (const side of [-1, 1]) {
    const left = side < 0;
    const lift = { curious: left ? 0 : 55 + Math.sin(t * 10) * 18, listening: 30 + Math.sin(t * 3) * 5, thinking: left ? 0 : 70,
                   speaking: 10 + Math.sin(t * 5 + (left ? 0 : 1.6)) * 12, happy: 80 + Math.sin(t * 14) * 10, asking: left ? 10 : 40, sleepy: -10 }[mood] ?? Math.sin(t * 1.6 + (left ? 0 : 1)) * 5;
    ctx.save();
    ctx.translate(side * s * 0.36, s * 0.16 - s * 0.26 * 0.35);
    ctx.rotate(((side * (25 + lift)) * Math.PI) / 180);
    const ag = ctx.createRadialGradient(0, s * 0.05, 0, 0, s * 0.05, s * 0.13);
    ag.addColorStop(0, C.light); ag.addColorStop(0.6, C.cyan); ag.addColorStop(1, C.deep);
    ctx.fillStyle = ag;
    roundRect(ctx, -s * 0.075, -s * 0.04, s * 0.15, s * 0.26, s * 0.075); ctx.fill();
    ctx.restore();
  }

  // Body
  const rx = s * 0.41, ry = s * 0.4;
  const wobble = mood === 'sleepy' ? 0.012 : 0.025 + energy * 0.05 + (mood === 'thinking' ? 0.02 : 0);
  ctx.save();
  ctx.shadowColor = rgba(tint, 0.85 * Math.min(g, 1)); ctx.shadowBlur = s * (0.2 + energy * 0.25);
  blobPath(ctx, rx, ry, t, wobble);
  const bg = ctx.createRadialGradient(-rx * 0.28, -ry * 0.44, s * 0.02, -rx * 0.28, -ry * 0.44, s * 0.62);
  bg.addColorStop(0, C.light); bg.addColorStop(0.45, C.cyan); bg.addColorStop(1, C.deep);
  ctx.fillStyle = bg; ctx.fill();
  ctx.restore();

  // Living light inside
  ctx.save();
  blobPath(ctx, rx, ry, t, wobble); ctx.clip();
  ctx.globalCompositeOperation = 'lighter';
  ctx.filter = `blur(${s * 0.09}px)`;
  const swirl = mood === 'thinking' ? 2.6 : mood === 'sleepy' ? 0.25 : 0.7;
  for (let i = 0; i < 3; i++) {
    const a = t * swirl * (i === 1 ? -1 : 1) + i * 2.1, r = s * (0.15 + energy * 0.1);
    ctx.fillStyle = i === 0 ? 'rgba(255,255,255,0.45)' : rgba(C.light, 0.5);
    ctx.beginPath(); ctx.arc(Math.cos(a) * s * 0.2, Math.sin(a * 1.3) * s * 0.16 + s * 0.12, r, 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();

  // Rim + gloss
  ctx.save();
  blobPath(ctx, rx, ry, t, wobble);
  const rim = ctx.createLinearGradient(0, -ry, 0, ry);
  rim.addColorStop(0, 'rgba(184,255,255,0)'); rim.addColorStop(1, 'rgba(184,255,255,0.8)');
  ctx.strokeStyle = rim; ctx.lineWidth = s * 0.02; ctx.stroke();
  ctx.translate(-s * 0.18, -s * 0.29); ctx.rotate((-24 * Math.PI) / 180);
  const gl = ctx.createLinearGradient(0, -s * 0.075, 0, s * 0.075);
  gl.addColorStop(0, 'rgba(255,255,255,0.85)'); gl.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = gl; ctx.filter = `blur(${s * 0.013}px)`;
  ctx.beginPath(); ctx.ellipse(0, 0, s * 0.17, s * 0.075, 0, 0, Math.PI * 2); ctx.fill();
  ctx.restore();
  if (mood === 'error') { ctx.fillStyle = rgba(C.red, 0.3); blobPath(ctx, rx, ry, t, wobble); ctx.fill(); }

  // Face screen
  const vw = s * 0.56, vh = s * 0.32, vx = -vw / 2 + (mood === 'curious' ? look.x * s * 0.02 : 0), vy = -s * 0.07 - vh / 2;
  const vg = ctx.createLinearGradient(0, vy, 0, vy + vh);
  vg.addColorStop(0, '#0d1f30'); vg.addColorStop(1, '#00080f');
  ctx.fillStyle = vg; roundRect(ctx, vx, vy, vw, vh, vh * 0.48); ctx.fill();
  ctx.strokeStyle = rgba(C.light, 0.45); ctx.lineWidth = Math.max(1, s * 0.011); ctx.stroke();

  drawEyes(ctx, vx, vy, vw, vh, t, mood, level, look);

  // Visor reflection
  const rg = ctx.createLinearGradient(0, vy, 0, vy + vh * 0.3);
  rg.addColorStop(0, 'rgba(255,255,255,0.22)'); rg.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = rg; roundRect(ctx, vx + vw * 0.09, vy + vh * 0.09, vw * 0.5, vh * 0.22, vh * 0.11); ctx.fill();
  ctx.restore();

  if (mood === 'sleepy') {
    ctx.save();
    for (let i = 0; i < 2; i++) {
      const p = (t * 0.35 + i * 0.5) % 1;
      ctx.globalAlpha = Math.sin(p * Math.PI) * 0.9;
      ctx.fillStyle = C.light;
      ctx.font = `800 ${s * (0.12 + p * 0.08)}px system-ui, sans-serif`;
      ctx.fillText('z', cx - s * 0.3 - p * s * 0.15, cy - s * 0.38 - p * s * 0.22);
    }
    ctx.restore();
  }
}

function drawEyes(ctx, vx, vy, w, h, t, mood, level, look) {
  const ew = w * 0.13, eh = h * 0.5, cy = vy + h * 0.5, xs = [vx + w * 0.31, vx + w * 0.69];
  const color = mood === 'asking' ? '#FFD980' : mood === 'error' ? '#FF999E' : C.light;
  let lx = look.x * w * 0.06, ly = look.y * h * 0.1;
  if (mood === 'listening') { lx *= 0.4; ly *= 0.4; }
  const b = blink(t);
  const fills = [], strokes = [];
  const pill = (x, y, pw, ph) => { const p = new Path2D(); roundRect(p, x - pw / 2, y - ph / 2, pw, ph, pw / 2); return p; };

  if (mood === 'idle' || mood === 'curious') { const k = mood === 'curious' ? 1.15 : 1; xs.forEach(x => fills.push(pill(x + lx, cy + ly, ew * k, eh * k * b))); }
  else if (mood === 'listening') { const dd = eh * (0.82 + level * 0.18); xs.forEach(x => { const p = new Path2D(); p.ellipse(x + lx, cy + ly, dd / 2, (dd * b) / 2, 0, 0, Math.PI * 2); fills.push(p); }); }
  else if (mood === 'thinking') { const dx = Math.sin(t * 0.8) * w * 0.05; fills.push(pill(xs[0] + dx, cy - h * 0.1, ew, eh * 0.45)); fills.push(pill(xs[1] + dx, cy - h * 0.12, ew, eh * 0.8 * b)); }
  else if (mood === 'speaking') {
    const hop = -level * h * 0.06;
    xs.forEach(x => fills.push(pill(x + lx * 0.5, vy + h * 0.4 + hop, ew, eh * 0.7 * b)));
    const mw = w * (0.1 + level * 0.1), mh = h * (0.07 + level * 0.16);
    const p = new Path2D(); roundRect(p, vx + w / 2 - mw / 2, vy + h * 0.8 - mh / 2, mw, mh, Math.min(mw, mh) / 2); fills.push(p);
  } else if (mood === 'happy') xs.forEach(x => { const p = new Path2D(); p.moveTo(x - ew * 0.9, cy + eh * 0.12); p.quadraticCurveTo(x, cy - eh * 0.6, x + ew * 0.9, cy + eh * 0.12); strokes.push(p); });
  else if (mood === 'sleepy') xs.forEach(x => { const p = new Path2D(); p.moveTo(x - ew * 0.8, cy); p.quadraticCurveTo(x, cy + eh * 0.28, x + ew * 0.8, cy); strokes.push(p); });
  else if (mood === 'asking') { fills.push(pill(xs[0], cy + h * 0.04, ew, eh * 0.75 * b)); fills.push(pill(xs[1], cy - h * 0.06, ew * 1.1, eh * 1.05 * b)); }
  else if (mood === 'error') xs.forEach((x, i) => { const dir = i === 0 ? 1 : -1, p = new Path2D(); p.moveTo(x - dir * ew * 0.7, cy - eh * 0.35); p.lineTo(x + dir * ew * 0.6, cy); p.lineTo(x - dir * ew * 0.7, cy + eh * 0.35); strokes.push(p); });

  ctx.save();
  ctx.shadowColor = C.cyan; ctx.shadowBlur = ew * 1.2;
  ctx.fillStyle = color; ctx.strokeStyle = color; ctx.lineWidth = ew * 0.55; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  fills.forEach(p => ctx.fill(p)); strokes.forEach(p => ctx.stroke(p));
  ctx.restore();
}


/** Animates a canvas. Returns a controller {set({mood, level, look}), stop()}. Frame rate drops when calm, pauses when hidden. */
function animateBlob(canvas, opts = {}) {
  const ctx = canvas.getContext('2d');
  const state = { mood: 'idle', level: 0, look: { x: 0, y: 0 }, tucked: false, still: false, ...opts };
  let last = 0, raf = 0, stopped = false;
  const dpr = window.devicePixelRatio || 1;
  const fit = () => { canvas.width = canvas.clientWidth * dpr; canvas.height = canvas.clientHeight * dpr; };
  fit();
  window.addEventListener('resize', fit);
  const frame = now => {
    if (stopped) return;
    raf = requestAnimationFrame(frame);
    if (document.hidden) return;
    const fps = state.still ? 0 : state.mood === 'sleepy' ? 6 : state.tucked ? 8 : (state.mood === 'idle' || state.mood === 'curious') ? 15 : 60;
    if (fps === 0 && last) return;
    if (fps && now - last < 1000 / fps) return;
    last = now;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.scale(dpr, dpr);
    const w = canvas.clientWidth, h = canvas.clientHeight, s = Math.min(w, h) / 1.85;
    drawBlob(ctx, w / 2, h / 2, s, state.still ? 1.0 : now / 1000, state);
  };
  raf = requestAnimationFrame(frame);
  return { set: patch => Object.assign(state, patch), stop: () => { stopped = true; cancelAnimationFrame(raf); }, state };
}

window.BlobArt = { drawBlob, animateBlob, colors: C };
