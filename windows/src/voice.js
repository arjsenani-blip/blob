// Blob's voice on Windows: offline speech recognition + the Kokoro "Daniel" voice (same as the Mac).
// Models are downloaded once, on first use, after the user agrees (~380 MB). Everything then runs offline.
'use strict';
const fs = require('fs');
const path = require('path');
const https = require('https');
const { Worker } = require('worker_threads');
const { execFile } = require('child_process');

const MODELS = [
  { key: 'moonshine', name: 'Speech recognition (Moonshine tiny)', mb: 30,
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2' },
  { key: 'kokoro', name: 'Blob\'s voice (Kokoro, Daniel)', mb: 350,
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2' },
];

class Voice {
  constructor(dir) {
    this.dir = dir;
    this.worker = null;
    this.pending = new Map();
    this.seq = 0;
    this.status = { tts: false, asr: false };
  }

  get installed() { return MODELS.every(m => fs.existsSync(path.join(this.dir, m.key, '.done'))); }
  get sizeMB() { return MODELS.reduce((s, m) => s + m.mb, 0); }

  call(msg, transfer) {
    if (!this.worker) {
      this.worker = new Worker(path.join(__dirname, 'voice-worker.js'));
      this.worker.on('message', m => { const p = this.pending.get(m.id); if (p) { this.pending.delete(m.id); m.ok ? p.resolve(m) : p.reject(new Error(m.error)); } });
      this.worker.on('error', e => { for (const p of this.pending.values()) p.reject(e); this.pending.clear(); this.worker = null; });
    }
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ ...msg, id }, transfer || []);
    });
  }

  async init() {
    if (!this.installed) return this.status;
    try { const r = await this.call({ type: 'init', dir: this.dir }); this.status = { tts: r.tts, asr: r.asr }; } catch { /* stays false */ }
    return this.status;
  }

  async speak(text, sid = 24) {
    const r = await this.call({ type: 'speak', text, sid });
    return { samples: r.samples, sampleRate: r.sampleRate };
  }

  async transcribe(samples, sampleRate) {
    const copy = Float32Array.from(samples);
    const r = await this.call({ type: 'transcribe', samples: copy, sampleRate }, [copy.buffer]);
    return r.text;
  }

  /** Downloads and unpacks the models. onProgress(fraction 0…1, label). */
  async download(onProgress) {
    fs.mkdirSync(this.dir, { recursive: true });
    const total = this.sizeMB;
    let doneMB = 0;
    for (const m of MODELS) {
      const target = path.join(this.dir, m.key);
      if (fs.existsSync(path.join(target, '.done'))) { doneMB += m.mb; continue; }
      fs.mkdirSync(target, { recursive: true });
      const archive = path.join(this.dir, m.key + '.tar.bz2');
      await fetchFile(m.url, archive, f => onProgress((doneMB + f * m.mb * 0.9) / total, `Downloading ${m.name}…`));
      onProgress((doneMB + m.mb * 0.9) / total, `Unpacking ${m.name}…`);
      await untar(archive, target);
      fs.rmSync(archive, { force: true });
      fs.writeFileSync(path.join(target, '.done'), new Date().toISOString());
      doneMB += m.mb;
    }
    onProgress(1, 'Ready');
    return this.init();
  }
}

function fetchFile(url, dest, onProgress, redirects = 0) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'Blob' } }, res => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects < 8) {
        res.resume();
        return resolve(fetchFile(res.headers.location, dest, onProgress, redirects + 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error(`Download failed (${res.statusCode})`)); }
      const size = parseInt(res.headers['content-length'] || '0', 10);
      let got = 0;
      const out = fs.createWriteStream(dest);
      res.on('data', c => { got += c.length; if (size) onProgress(got / size); });
      res.pipe(out);
      out.on('finish', () => out.close(resolve));
      out.on('error', reject);
    }).on('error', reject);
  });
}

// Windows 10/11 ship bsdtar as tar.exe, which unpacks .tar.bz2. macOS has it too (for development).
function untar(archive, dir) {
  return new Promise((resolve, reject) => execFile('tar', ['-xjf', archive, '-C', dir], { windowsHide: true }, e => (e ? reject(e) : resolve())));
}

module.exports = { Voice, MODELS };
