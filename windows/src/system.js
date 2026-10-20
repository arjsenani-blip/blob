// What Blob can do on Windows: open apps and sites, volume and media keys, YouTube, search, music, timers.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');
const { shell, Notification } = require('electron');
const { execFile } = require('child_process');

const isWin = process.platform === 'win32';

const SITES = {
  youtube: 'https://www.youtube.com', gmail: 'https://mail.google.com', 'google classroom': 'https://classroom.google.com',
  classroom: 'https://classroom.google.com', 'google docs': 'https://docs.google.com', 'google drive': 'https://drive.google.com',
  netflix: 'https://www.netflix.com', twitter: 'https://x.com', x: 'https://x.com', instagram: 'https://www.instagram.com',
  reddit: 'https://www.reddit.com', amazon: 'https://www.amazon.com', chatgpt: 'https://chatgpt.com', claude: 'https://claude.ai',
  github: 'https://github.com', canvas: 'https://canvas.instructure.com', quizlet: 'https://quizlet.com', 'khan academy': 'https://www.khanacademy.org',
  google: 'https://www.google.com', wikipedia: 'https://www.wikipedia.org', twitch: 'https://www.twitch.tv', espn: 'https://www.espn.com',
  'youtube music': 'https://music.youtube.com', 'google calendar': 'https://calendar.google.com', desmos: 'https://www.desmos.com/calculator',
};

/** Start-menu shortcuts (what Windows search uses), name → path. */
function startMenuApps() {
  const roots = isWin
    ? [path.join(process.env.ProgramData || 'C:\\ProgramData', 'Microsoft/Windows/Start Menu/Programs'),
       path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData/Roaming'), 'Microsoft/Windows/Start Menu/Programs')]
    : ['/Applications', '/System/Applications'];                      // development on a Mac
  const out = new Map();
  const walk = (dir, depth) => {
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (/\.(lnk|url|app)$/i.test(e.name)) {
        const name = e.name.replace(/\.(lnk|url|app)$/i, '').toLowerCase();
        if (!/uninstall|readme|help|website/.test(name) && !out.has(name)) out.set(name, p);
      } else if (e.isDirectory() && depth < 3) walk(p, depth + 1);
    }
  };
  roots.forEach(r => walk(r, 0));
  return out;
}
let appCache = null, appCacheAt = 0;

function findApp(raw) {
  if (!appCache || Date.now() - appCacheAt > 60_000) { appCache = startMenuApps(); appCacheAt = Date.now(); }
  const aliases = { chrome: 'google chrome', vscode: 'visual studio code', 'vs code': 'visual studio code', word: 'word', excel: 'excel',
                    powerpoint: 'powerpoint', settings: 'settings', 'file explorer': 'file explorer', explorer: 'file explorer', edge: 'microsoft edge' };
  const want = aliases[raw.toLowerCase().trim()] || raw.toLowerCase().trim();
  if (!want) return null;
  const names = [...appCache.keys()];
  const hit = names.find(n => n === want) || names.find(n => n.startsWith(want)) || names.find(n => n.includes(want));
  return hit ? { name: hit, path: appCache.get(hit) } : null;
}

function openApp(name) {
  const app = findApp(name);
  if (!app) return null;
  shell.openPath(app.path);
  return app.name.replace(/\b\w/g, c => c.toUpperCase());
}

function quitApp(name) {
  if (!isWin) return Promise.resolve(false);
  return new Promise(resolve => execFile('powershell.exe', ['-NoProfile', '-Command',
    `$p = Get-Process | Where-Object { $_.MainWindowTitle -and ($_.ProcessName -like '*${name.replace(/[^\w ]/g, '')}*' -or $_.MainWindowTitle -like '*${name.replace(/[^\w ]/g, '')}*') }; if ($p) { $p | ForEach-Object { $_.CloseMainWindow() | Out-Null }; 'ok' }`],
    { windowsHide: true }, (e, out) => resolve(!e && /ok/.test(out))));
}

const openUrl = url => shell.openExternal(url);

/** Volume and media keys via the Windows virtual-key codes (no extra software). */
function keys(codes) {
  if (!isWin) return Promise.resolve();
  const script = `$w = New-Object -ComObject WScript.Shell; ${codes.map(c => `$w.SendKeys([char]${c})`).join('; ')}`;
  return new Promise(r => execFile('powershell.exe', ['-NoProfile', '-Command', script], { windowsHide: true }, () => r()));
}
const VK = { volUp: 175, volDown: 174, mute: 173, playPause: 179, next: 176, prev: 177 };
const volume = {
  up: () => keys(Array(8).fill(VK.volUp)),
  down: () => keys(Array(8).fill(VK.volDown)),
  mute: () => keys([VK.mute]),
  set: pct => keys([...Array(50).fill(VK.volDown), ...Array(Math.round(Math.max(0, Math.min(100, pct)) / 2)).fill(VK.volUp)]),
};
const media = { playPause: () => keys([VK.playPause]), next: () => keys([VK.next]), prev: () => keys([VK.prev]) };

/** Finds the top YouTube result and opens it playing. No account or API key needed. */
function playYouTube(query) {
  const q = encodeURIComponent(query);
  return new Promise(resolve => {
    https.get(`https://www.youtube.com/results?search_query=${q}`, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36', 'Accept-Language': 'en-US,en;q=0.9' } }, res => {
      let html = '';
      res.on('data', c => { html += c; if (html.length > 3e6) res.destroy(); });
      res.on('end', () => {
        const m = html.match(/"videoId":"([A-Za-z0-9_-]{11})"/);
        openUrl(m ? `https://www.youtube.com/watch?v=${m[1]}` : `https://www.youtube.com/results?search_query=${q}`);
        resolve(!!m);
      });
    }).on('error', () => { openUrl(`https://www.youtube.com/results?search_query=${q}`); resolve(false); });
  });
}

function searchWeb(query, site) {
  const q = encodeURIComponent(query);
  const urls = { youtube: `https://www.youtube.com/results?search_query=${q}`, amazon: `https://www.amazon.com/s?k=${q}`,
                 wikipedia: `https://en.wikipedia.org/wiki/Special:Search?search=${q}`, maps: `https://www.google.com/maps/search/${q}`,
                 images: `https://www.google.com/search?tbm=isch&q=${q}`, reddit: `https://www.reddit.com/search/?q=${q}` };
  openUrl(urls[site] || `https://www.google.com/search?q=${q}`);
}

/** Spotify if installed, otherwise YouTube. */
async function playMusic(query, app) {
  if (app === 'spotify' || (!app && findApp('spotify'))) {
    openUrl(`spotify:search:${encodeURIComponent(query)}`);
    return 'Searched Spotify for ' + query + ' — press play on the top result.';
  }
  await playYouTube(query + ' audio');
  return 'Playing ' + query + ' on YouTube.';
}

function timer(seconds, label = 'Timer') {
  setTimeout(() => new Notification({ title: `⏰ ${label}`, body: 'Your Blob timer is up, sir.' }).show(), Math.max(1, seconds) * 1000);
}

module.exports = { SITES, findApp, openApp, quitApp, openUrl, volume, media, playYouTube, searchWeb, playMusic, timer };
