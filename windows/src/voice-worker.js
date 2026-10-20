// Runs speech recognition (Moonshine) and Blob's voice (Kokoro "Daniel") off the main thread, fully offline.
'use strict';
const { parentPort } = require('worker_threads');
const fs = require('fs');
const path = require('path');
const sherpa = require('sherpa-onnx-node');

let tts = null, asr = null;

function findDir(base, marker) {
  if (!fs.existsSync(base)) return null;
  for (const d of fs.readdirSync(base)) {
    const p = path.join(base, d);
    if (fs.existsSync(path.join(p, marker))) return p;
  }
  return null;
}

function loadTts(dir) {
  const m = findDir(path.join(dir, 'kokoro'), 'model.onnx');
  if (!m) return null;
  return new sherpa.OfflineTts({ model: { kokoro: {
    model: path.join(m, 'model.onnx'), voices: path.join(m, 'voices.bin'), tokens: path.join(m, 'tokens.txt'),
    dataDir: path.join(m, 'espeak-ng-data'), dictDir: path.join(m, 'dict'), lexicon: path.join(m, 'lexicon-gb-en.txt'),
  }, numThreads: 2, debug: false }, maxNumSentences: 1 });
}

function loadAsr(dir) {
  const m = findDir(path.join(dir, 'moonshine'), 'tokens.txt');
  if (!m) return null;
  return new sherpa.OfflineRecognizer({
    featConfig: { sampleRate: 16000, featureDim: 80 },
    modelConfig: { moonshine: { encoder: path.join(m, 'encoder_model.ort'), mergedDecoder: path.join(m, 'decoder_model_merged.ort') },
                   tokens: path.join(m, 'tokens.txt'), numThreads: 2, provider: 'cpu', debug: 0 },
  });
}

parentPort.on('message', msg => {
  try {
    if (msg.type === 'init') {
      tts = tts || loadTts(msg.dir);
      asr = asr || loadAsr(msg.dir);
      parentPort.postMessage({ id: msg.id, ok: true, tts: !!tts, asr: !!asr });
    } else if (msg.type === 'speak') {
      if (!tts) throw new Error('voice not installed');
      const a = tts.generate({ text: msg.text, sid: msg.sid ?? 24, speed: msg.speed ?? 1.0 });
      const samples = Float32Array.from(a.samples);
      parentPort.postMessage({ id: msg.id, ok: true, samples, sampleRate: a.sampleRate }, [samples.buffer]);
    } else if (msg.type === 'transcribe') {
      if (!asr) throw new Error('speech recognition not installed');
      const s = asr.createStream();
      s.acceptWaveform({ samples: msg.samples, sampleRate: msg.sampleRate });
      asr.decode(s);
      parentPort.postMessage({ id: msg.id, ok: true, text: asr.getResult(s).text.trim() });
    }
  } catch (e) {
    parentPort.postMessage({ id: msg.id, ok: false, error: String(e && e.message || e) });
  }
});
