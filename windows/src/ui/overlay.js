// The corner Blob: click or Ctrl+Shift+B, talk, Blob answers out loud.
'use strict';
const $ = id => document.getElementById(id);
const art = BlobArt.animateBlob($('blob'));
const ui = { phase: 'resting', hovering: false, sleeping: false, celebrating: false, error: false, lastActive: Date.now(), bubble: false };

// ---------------------------------------------------------------- appearance
function mood() {
  if (ui.error && ui.phase !== 'resting') return 'error';
  if (ui.phase === 'listening') return 'listening';
  if (ui.phase === 'thinking') return 'thinking';
  if (ui.phase === 'speaking') return 'speaking';
  if (ui.celebrating) return 'happy';
  if (ui.hovering) return 'curious';
  if (ui.sleeping) return 'sleepy';
  return 'idle';
}
function render() {
  const tucked = ui.phase === 'resting' && !ui.hovering && !ui.bubble;
  $('blobwrap').classList.toggle('tucked', tucked);
  $('bubble').classList.toggle('hidden', !ui.bubble);
  $('hint').classList.toggle('hidden', !(ui.hovering && ui.phase === 'resting' && !ui.bubble));
  $('phase').textContent = { listening: 'listening', thinking: 'thinking', speaking: 'talking' }[ui.phase] || '';
  $('mic').classList.toggle('on', ui.phase === 'listening');
  art.set({ mood: mood(), tucked });
}
function setPhase(p) { ui.phase = p; if (p !== 'resting') { ui.lastActive = Date.now(); ui.sleeping = false; } render(); }
function show({ heard, status, reply, error } = {}) {
  if (heard !== undefined) $('heard').textContent = heard ? `“${heard}”` : '';
  if (status !== undefined) $('status').textContent = status || '';
  if (reply !== undefined) $('reply').textContent = reply || '';
  $('reply').classList.toggle('error', !!error);
  ui.error = !!error;
  ui.bubble = true;
  render();
}
let hideTimer = null;
function scheduleHide() {
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => { if (ui.phase === 'resting' && !$('typed').value && document.activeElement !== $('typed')) { ui.bubble = false; render(); } }, 12000);
}
function celebrate() { ui.celebrating = true; render(); setTimeout(() => { ui.celebrating = false; render(); }, 1800); }
setInterval(() => { if (ui.phase === 'resting' && !ui.hovering && !ui.sleeping && Date.now() - ui.lastActive > 90_000) { ui.sleeping = true; render(); } }, 5000);

// ---------------------------------------------------------------- click-through: only Blob and the bubble catch the mouse
let interactive = false;
window.addEventListener('mousemove', e => {
  const r = $('blobwrap').getBoundingClientRect();
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  const overBlob = Math.hypot(e.clientX - cx, e.clientY - cy) < 62;
  const b = $('bubble').getBoundingClientRect();
  const overBubble = ui.bubble && e.clientX >= b.left - 6 && e.clientX <= b.right + 6 && e.clientY >= b.top - 6 && e.clientY <= b.bottom + 6;
  const want = overBlob || overBubble;
  if (want !== interactive) { interactive = want; blob.overlayInteractive(want); }
  if (overBlob !== ui.hovering) { ui.hovering = overBlob; if (overBlob) { ui.sleeping = false; ui.lastActive = Date.now(); } render(); }
  if (ui.phase !== 'resting' || ui.hovering) {
    const d = Math.max(1, Math.hypot(e.clientX - cx, e.clientY - cy));
    art.set({ look: { x: (e.clientX - cx) / d * Math.min(1, d / 300), y: (e.clientY - cy) / d * Math.min(1, d / 300) } });
  }
});
document.addEventListener('mouseleave', () => { if (interactive) { interactive = false; blob.overlayInteractive(false); } if (ui.hovering) { ui.hovering = false; render(); } });

// ---------------------------------------------------------------- listening (offline speech recognition)
let mic = null;
async function listen() {
  stopSpeaking();
  const st = await blob.state();
  if (!st.voice.installed || !st.voice.asr) { offerDownload(st.voice.sizeMB); return; }
  try {
    await blob.micAccess();
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
    const ctx = new AudioContext({ sampleRate: 16000 });
    const src = ctx.createMediaStreamSource(stream);
    const proc = ctx.createScriptProcessor(2048, 1, 1);
    const chunks = [];
    let floor = 0.005, spoke = false, lastLoud = performance.now();
    const started = performance.now();
    proc.onaudioprocess = ev => {
      const data = ev.inputBuffer.getChannelData(0);
      chunks.push(new Float32Array(data));
      let sum = 0; for (let i = 0; i < data.length; i++) sum += data[i] * data[i];
      const rms = Math.sqrt(sum / data.length);
      floor = rms < floor ? floor * 0.9 + rms * 0.1 : floor * 0.999 + rms * 0.001;
      const loud = rms > Math.max(floor * 3, 0.01);
      if (loud) { spoke = true; lastLoud = performance.now(); }
      art.set({ level: Math.min(1, Math.max(0, (20 * Math.log10(Math.max(rms, 1e-5)) + 50) / 40)) });
      const now = performance.now();
      if ((spoke && now - lastLoud > 1300) || (!spoke && now - started > 7000) || now - started > 40000) finish();
    };
    src.connect(proc); proc.connect(ctx.destination);
    mic = { stream, ctx, chunks, finish: null };
    function finish() {
      if (!mic) return;
      const m = mic; mic = null;
      proc.disconnect(); src.disconnect(); m.stream.getTracks().forEach(t => t.stop()); m.ctx.close();
      art.set({ level: 0 });
      const total = m.chunks.reduce((n, c) => n + c.length, 0);
      const samples = new Float32Array(total); let o = 0; for (const c of m.chunks) { samples.set(c, o); o += c.length; }
      heardAudio(spoke ? samples : null);
    }
    mic.finish = finish;
    setPhase('listening');
    show({ heard: '', status: '', reply: 'Listening…' });
    blob.warmUp();
  } catch (e) {
    setPhase('resting'); show({ reply: 'I need the microphone, sir. Allow it in Windows Settings → Privacy & security → Microphone.', error: true });
  }
}
async function heardAudio(samples) {
  if (!samples) { setPhase('resting'); show({ reply: "I didn't catch that, sir. Press Ctrl+Shift+B to try again." }); scheduleHide(); return; }
  setPhase('thinking'); show({ reply: '', status: 'Understanding…' });
  const text = await blob.transcribe(samples, 16000).catch(() => '');
  if (!text) { setPhase('resting'); show({ status: '', reply: "I didn't catch that, sir." }); scheduleHide(); return; }
  submit(text);
}

// ---------------------------------------------------------------- answering + speaking (sentences start as soon as they're ready)
let speech = null;
function startSpeech() {
  stopSpeaking();
  speech = { queue: [], open: true, consumed: 0, out: new AudioContext(), playing: false, cancelled: false };
  const an = speech.out.createAnalyser(); an.fftSize = 512; an.connect(speech.out.destination); speech.an = an;
  pump();
}
function feed(text, final) {
  if (!speech) return;
  const s = speech;
  let i = s.consumed;
  for (; i < text.length; i++) {
    const c = text[i];
    const boundary = '.!?…'.includes(c) && text[i + 1] === ' ';
    const clause = !s.queue.length && s.consumed === 0 && c === ',' && i - s.consumed > 45 && text[i + 1] === ' ';
    if (boundary || clause) { s.queue.push(text.slice(s.consumed, i + 1).trim()); s.consumed = i + 1; }
  }
  if (final) { const rest = text.slice(s.consumed).trim(); if (rest) s.queue.push(rest); s.consumed = text.length; s.open = false; }
}
async function pump() {
  const s = speech;
  let next = null;
  const render1 = t => blob.speak(t).catch(() => null);
  while (s && !s.cancelled) {
    if (!s.queue.length) { if (!s.open) break; await new Promise(r => setTimeout(r, 40)); continue; }
    const sentence = s.queue.shift();
    const audio = await (next && next.t === sentence ? next.p : render1(sentence));
    next = s.queue[0] ? { t: s.queue[0], p: render1(s.queue[0]) } : null;
    if (s.cancelled) break;
    if (audio && audio.samples) await playSamples(s, audio);
    else await sayFallback(sentence);
  }
  if (s && !s.cancelled) { speech = null; doneSpeaking(); }
}
function playSamples(s, { samples, sampleRate }) {
  return new Promise(resolve => {
    const buf = s.out.createBuffer(1, samples.length, sampleRate);
    buf.copyToChannel(samples instanceof Float32Array ? samples : Float32Array.from(samples), 0);
    const node = s.out.createBufferSource(); node.buffer = buf; node.connect(s.an);
    const arr = new Uint8Array(s.an.fftSize);
    const meter = setInterval(() => { s.an.getByteTimeDomainData(arr); let m = 0; for (const v of arr) m = Math.max(m, Math.abs(v - 128)); art.set({ level: Math.min(1, m / 60) }); }, 60);
    node.onended = () => { clearInterval(meter); art.set({ level: 0 }); resolve(); };
    s.node = node; node.start();
  });
}
function sayFallback(text) {
  // Before the voice is downloaded: Windows' built-in voices (British if available).
  return new Promise(resolve => {
    const u = new SpeechSynthesisUtterance(text);
    const v = speechSynthesis.getVoices();
    u.voice = v.find(x => /en-GB/i.test(x.lang) && /george|ryan|male/i.test(x.name)) || v.find(x => /en-GB/i.test(x.lang)) || null;
    u.rate = 0.98; u.pitch = 0.94;
    const pulse = setInterval(() => art.set({ level: 0.3 + Math.random() * 0.6 }), 80);
    u.onend = u.onerror = () => { clearInterval(pulse); art.set({ level: 0 }); resolve(); };
    speechSynthesis.speak(u);
  });
}
function stopSpeaking() {
  if (speech) { speech.cancelled = true; try { speech.node?.stop(); } catch {} speech.out.close(); speech = null; }
  speechSynthesis.cancel();
  art.set({ level: 0 });
}
function doneSpeaking() { if (ui.phase === 'speaking') { setPhase('resting'); celebrate(); scheduleHide(); } }

let asking = 0;
async function submit(text) {
  const myTurn = ++asking;
  stopSpeaking();
  setPhase('thinking');
  show({ heard: text, status: 'Thinking…', reply: '' });
  const st = await blob.state();
  let streaming = false;
  const off = blob.onPartial(partial => {
    if (myTurn !== asking) return;
    if (!streaming) { streaming = true; setPhase('speaking'); show({ status: '' }); if (st.prefs.speak) startSpeech(); }
    show({ reply: partial }); feed(partial, false);
  });
  const answer = await blob.ask(text).catch(e => e.message);
  off();
  if (myTurn !== asking) return;
  show({ status: '', reply: answer });
  if (!st.prefs.speak) { setPhase('resting'); celebrate(); scheduleHide(); return; }
  if (!streaming) { setPhase('speaking'); startSpeech(); }
  feed(answer, true);
}

// ---------------------------------------------------------------- voice download (asks first)
function offerDownload(mb) {
  ui.bubble = true; render();
  $('dlsize').textContent = mb;
  $('download').classList.remove('hidden');
  show({ reply: 'You can type to me now, sir — or download my voice to talk.' });
}
$('dlbtn').onclick = async () => {
  $('dlbtn').disabled = true;
  const off = blob.onVoiceProgress((f, label) => { $('dlbar').style.width = `${Math.round(f * 100)}%`; $('dllabel').textContent = label; });
  try { await blob.voiceDownload(); $('download').classList.add('hidden'); show({ reply: 'All set, sir. Press Ctrl+Shift+B and talk.' }); celebrate(); }
  catch (e) { show({ reply: `The download didn't finish: ${e.message}`, error: true }); $('dlbtn').disabled = false; }
  off();
};

// ---------------------------------------------------------------- inputs
function activate() {
  if (ui.phase === 'listening') { mic?.finish(); return; }
  listen();
}
blob.onActivate(activate);
$('blobwrap').addEventListener('click', activate);
$('mic').addEventListener('click', activate);
$('close').addEventListener('click', () => { asking++; stopSpeaking(); if (mic) { const m = mic; mic = null; m.stream.getTracks().forEach(t => t.stop()); m.ctx.close(); } setPhase('resting'); ui.bubble = false; render(); });
$('typed').addEventListener('focus', () => blob.overlayFocus());
$('typed').addEventListener('keydown', e => {
  if (e.key === 'Enter' && $('typed').value.trim()) { const t = $('typed').value.trim(); $('typed').value = ''; submit(t); }
  if (e.key === 'Escape') $('close').click();
});
$('blobwrap').addEventListener('contextmenu', e => { e.preventDefault(); blob.openBrain(); });

// Development screenshots
blob.onStage(stage => {
  if (stage === 'idle') { setPhase('resting'); ui.bubble = false; ui.hovering = true; render(); }
  if (stage === 'listening') { setPhase('listening'); show({ heard: '', status: '', reply: 'Listening…' }); }
  if (stage === 'thinking') { setPhase('thinking'); show({ heard: "What's due tomorrow?", status: 'Thinking…', reply: '' }); }
  if (stage === 'speaking') { setPhase('speaking'); show({ status: '', reply: "You've the titration lab report and Spanish vocab due tomorrow, sir. Shall I check you in?" }); }
});
render();
