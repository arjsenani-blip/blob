// Blob for Windows — main process: the corner Blob, the "Blob's Brain" planner window, tray, hotkey, sync.
'use strict';
const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, screen, nativeImage, systemPreferences } = require('electron');
const path = require('path');
const fs = require('fs');
const { Store } = require('./store');
const { Voice } = require('./voice');
const { Brain } = require('./brain');
const { GoogleAccount, syncDrive, syncClassroom, CLASSROOM, DRIVE } = require('./google');

if (!app.requestSingleInstanceLock()) { app.quit(); process.exit(0); }
app.setAppUserModelId('com.arjunsenani.blob');

const DATA = app.getPath('userData');
const store = new Store(DATA);
const voice = new Voice(path.join(DATA, 'voice'));
const brain = new Brain(store);

// ---- Preferences (this PC only) ----
const PREFS_FILE = path.join(DATA, 'prefs.json');
let prefs = { name: 'Arjun', speak: true, voiceSid: 24, googleClientId: '', googleClientSecret: '', openAtLogin: true };
try { prefs = { ...prefs, ...JSON.parse(fs.readFileSync(PREFS_FILE, 'utf8')) }; } catch { /* defaults */ }
const savePrefs = () => fs.writeFileSync(PREFS_FILE, JSON.stringify(prefs, null, 2));
const googleConfig = () => ({ clientId: prefs.googleClientId, clientSecret: prefs.googleClientSecret });
const school = new GoogleAccount(DATA, 'school', googleConfig);
const personal = new GoogleAccount(DATA, 'personal', googleConfig);
const syncAccount = () => (personal.signedIn ? personal : school.signedIn && school.hasScope(DRIVE) ? school : null);

let overlay = null, brainWin = null, tray = null;
const ICON = path.join(__dirname, '../assets/icon.png');
const PANEL = { w: 420, h: 520 };

function placeOverlay() {
  if (!overlay) return;
  const wa = screen.getPrimaryDisplay().workArea;
  overlay.setBounds({ x: wa.x + wa.width - PANEL.w, y: wa.y + wa.height - PANEL.h, width: PANEL.w, height: PANEL.h });
}

function createOverlay() {
  overlay = new BrowserWindow({
    width: PANEL.w, height: PANEL.h, frame: false, transparent: true, resizable: false, movable: false, skipTaskbar: true,
    alwaysOnTop: true, hasShadow: false, show: false, focusable: true, backgroundColor: '#00000000',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), backgroundThrottling: true },
  });
  overlay.setAlwaysOnTop(true, 'screen-saver');
  overlay.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  overlay.setIgnoreMouseEvents(true, { forward: true });        // clicks pass through except over Blob / the bubble
  overlay.loadFile(path.join(__dirname, 'ui/overlay.html'));
  overlay.once('ready-to-show', () => { placeOverlay(); overlay.showInactive(); });
  screen.on('display-metrics-changed', placeOverlay);
}

function openBrain() {
  if (brainWin && !brainWin.isDestroyed()) { brainWin.show(); brainWin.focus(); return; }
  brainWin = new BrowserWindow({
    width: 1120, height: 780, minWidth: 760, minHeight: 560, title: "Blob's Brain", icon: ICON, backgroundColor: '#0d1117',
    autoHideMenuBar: true, webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  brainWin.loadFile(path.join(__dirname, 'ui/brain.html'));
}

const broadcast = (ch, ...a) => [overlay, brainWin].forEach(w => w && !w.isDestroyed() && w.webContents.send(ch, ...a));

// ---- Sync (Drive) & Classroom, in the background ----
let syncing = false, syncTimer = null, lastSync = null, syncError = null, lastClassroom = null, classroomError = null;
async function syncNow() {
  const acct = syncAccount();
  if (!acct || syncing) return;
  syncing = true;
  try { await syncDrive(acct, store); lastSync = new Date(); syncError = null; } catch (e) { syncError = e.message; }
  syncing = false;
  broadcast('state-changed');
}
async function classroomNow() {
  if (!school.signedIn) return 0;
  try { const n = await syncClassroom(school, store); lastClassroom = new Date(); classroomError = null; return n; }
  catch (e) { classroomError = e.message; return 0; } finally { broadcast('state-changed'); }
}
store.on('changed', () => {
  broadcast('state-changed');
  clearTimeout(syncTimer);
  syncTimer = setTimeout(syncNow, 2500);
});

// ---- IPC: what the windows can ask for ----
const handle = (ch, fn) => ipcMain.handle(ch, (_e, ...a) => fn(...a));

handle('state', () => ({
  tasks: store.tasks, plan: store.todayPlan, settings: store.doc.settings, courses: store.knownCourses, prefs,
  voice: { installed: voice.installed, sizeMB: voice.sizeMB, ...voice.status },
  google: { school: { signedIn: school.signedIn, email: school.email }, personal: { signedIn: personal.signedIn, email: personal.email },
            syncAccount: syncAccount()?.email || null, lastSync, syncError, lastClassroom, classroomError, syncing },
  claude: brain.claudePath,
}));
handle('occurrences', (start, end) => store.occurrencesIn(new Date(start), new Date(end)));
handle('parse', text => store.parse(text));
handle('add', (text, kind) => store.add(store.parse(text), kind || undefined));
handle('upsertTask', t => store.upsertTask(t));
handle('toggleTask', id => store.toggleTask(id));
handle('deleteTask', id => store.deleteTask(id));
handle('upsertEvent', e => store.upsertEvent(e));
handle('deleteEvent', id => store.deleteEvent(id));
handle('checkIn', () => store.checkIn());
handle('startBlock', id => store.updateBlock(id, { startedAt: new Date() }));
handle('completeBlock', id => store.completeBlock(id));
handle('updateSettings', patch => store.updateSettings(patch));
handle('setPrefs', patch => { prefs = { ...prefs, ...patch }; savePrefs(); applyLoginItem(); broadcast('state-changed'); });

handle('ask', async text => {
  brain.warmUp();
  return brain.respond(text, partial => overlay?.webContents.send('brain-partial', partial));
});
handle('warmUp', () => { brain.warmUp(); voice.init(); });
handle('transcribe', (samples, rate) => voice.transcribe(samples, rate));
handle('speak', async text => (voice.installed ? voice.speak(text, prefs.voiceSid) : null));
handle('voiceDownload', async () => {
  const s = await voice.download((f, label) => broadcast('voice-progress', f, label));
  broadcast('state-changed');
  return s;
});

handle('googleSignIn', async role => {
  const acct = role === 'school' ? school : personal;
  await acct.signIn(role === 'school' ? [...CLASSROOM, DRIVE] : [DRIVE]);
  broadcast('state-changed');
  if (role === 'school') classroomNow();
  syncNow();
});
handle('googleSignOut', role => { (role === 'school' ? school : personal).signOut(); broadcast('state-changed'); });
handle('syncNow', syncNow);
handle('classroomNow', classroomNow);

handle('overlayInteractive', on => overlay?.setIgnoreMouseEvents(!on, { forward: true }));
handle('overlayFocus', () => { overlay?.setFocusable(true); overlay?.focus(); });
handle('openBrain', openBrain);
handle('micAccess', async () => (process.platform === 'darwin' ? systemPreferences.askForMediaAccess('microphone') : true));

function applyLoginItem() {
  if (process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: !!prefs.openAtLogin });
}

app.whenReady().then(async () => {
  createOverlay();
  tray = new Tray(nativeImage.createFromPath(ICON).resize({ width: 16, height: 16 }));
  tray.setToolTip('Blob — Ctrl+Shift+B to talk');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Talk to Blob   (Ctrl+Shift+B)', click: () => overlay?.webContents.send('activate') },
    { label: "Open Blob's Brain", click: openBrain },
    { type: 'separator' },
    { label: 'Quit Blob', click: () => app.quit() },
  ]));
  tray.on('click', openBrain);
  globalShortcut.register('CommandOrControl+Shift+B', () => overlay?.webContents.send('activate'));
  applyLoginItem();
  voice.init().then(() => broadcast('state-changed'));
  brain.findClaude();
  if (!process.argv.includes('--background')) openBrain();
  syncNow();
  if (school.signedIn) classroomNow();
  setInterval(syncNow, 90_000);
  setInterval(() => school.signedIn && classroomNow(), 15 * 60_000);

  // `--snapshot <dir>`: save screenshots of both windows (for development), then quit.
  const snap = process.argv.indexOf('--snapshot');
  if (snap > 0) {
    const dir = process.argv[snap + 1];
    setTimeout(async () => {
      for (const [name, w, stage] of [['brain-today', brainWin, 'today'], ['brain-calendar', brainWin, 'calendar'], ['brain-assignments', brainWin, 'tasks'], ['brain-settings', brainWin, 'settings']]) {
        w.webContents.send('stage', stage); await new Promise(r => setTimeout(r, 900));
        fs.writeFileSync(path.join(dir, name + '.png'), (await w.webContents.capturePage()).toPNG());
      }
      for (const stage of ['idle', 'listening', 'thinking', 'speaking']) {
        overlay.webContents.send('stage', stage); await new Promise(r => setTimeout(r, 900));
        fs.writeFileSync(path.join(dir, 'overlay-' + stage + '.png'), (await overlay.webContents.capturePage()).toPNG());
      }
      app.quit();
    }, 3500);
  }
});

app.on('second-instance', openBrain);
app.on('window-all-closed', e => e.preventDefault?.());       // keep running in the tray
app.on('will-quit', () => globalShortcut.unregisterAll());
