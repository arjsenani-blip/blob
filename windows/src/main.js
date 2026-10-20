// Blob for Windows — main process: the corner Blob, the "Blob's Brain" planner window, tray, hotkey, sync.
'use strict';
const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, screen, nativeImage, systemPreferences } = require('electron');
const path = require('path');
const fs = require('fs');
const { Store } = require('./store');
const { Voice } = require('./voice');
const { Brain } = require('./brain');
const { GoogleAccount, syncDrive, syncClassroom, fetchCalendarEvents, pushEvents, syncTasks, CLASSROOM, DRIVE, CALENDAR, TASKS } = require('./google');
const tracking = require('./core/tracking');
const { parseLog, bestStep } = require('./core/progresslog');

if (!app.requestSingleInstanceLock()) { app.quit(); process.exit(0); }
app.setAppUserModelId('com.arjunsenani.blob');

// `--data-dir <folder>`: use a separate data folder (for screenshots and testing).
const dataArg = process.argv.indexOf('--data-dir');
if (dataArg > 0) app.setPath('userData', process.argv[dataArg + 1]);
const DATA = app.getPath('userData');
const store = new Store(DATA);
const voice = new Voice(path.join(DATA, 'voice'));
const brain = new Brain(store);

// ---- Preferences (this PC only) ----
const PREFS_FILE = path.join(DATA, 'prefs.json');
let prefs = { name: 'Arjun', speak: true, voiceSid: 24, googleClientId: '', googleClientSecret: '', openAtLogin: true,
              googleCalendarOn: false, googleEventsPushOn: false, googleTasksOn: false, googlePushed: {} };
try { prefs = { ...prefs, ...JSON.parse(fs.readFileSync(PREFS_FILE, 'utf8')) }; } catch { /* defaults */ }
const savePrefs = () => fs.writeFileSync(PREFS_FILE, JSON.stringify(prefs, null, 2));
const googleConfig = () => ({ clientId: prefs.googleClientId, clientSecret: prefs.googleClientSecret });
const school = new GoogleAccount(DATA, 'school', googleConfig);
const personal = new GoogleAccount(DATA, 'personal', googleConfig);
const syncAccount = () => (personal.signedIn ? personal : school.signedIn && school.hasScope(DRIVE) ? school : null);
const calendarAccount = () => [personal, school].find(a => a.signedIn && a.hasScope(CALENDAR[0])) || null;
const tasksAccount = () => [personal, school].find(a => a.signedIn && a.hasScope(TASKS)) || null;

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
  try { const r = await syncClassroom(school, store); lastClassroom = new Date(); classroomError = null; return r.added; }
  catch (e) { classroomError = e.message; return 0; } finally { broadcast('state-changed'); }
}

// ---- Google Calendar & Google Tasks ----
let gcalEvents = [], gcalRead = 0, gcalError = null, gcalBusy = false, gcalTimer = null;
try { gcalEvents = JSON.parse(fs.readFileSync(path.join(DATA, 'google-calendar-cache.json'), 'utf8')).map(e => ({ ...e, start: new Date(e.start), end: new Date(e.end) })); } catch { /* none yet */ }
async function calendarNow(force = false) {
  if (gcalBusy) return;
  gcalBusy = true;
  try {
    const acct = calendarAccount();
    if (acct && prefs.googleCalendarOn && (force || Date.now() - gcalRead > 5 * 60e3)) {
      const now = Date.now();
      gcalEvents = await fetchCalendarEvents(acct, new Date(now - 30 * 86400e3), new Date(now + 180 * 86400e3));
      gcalRead = Date.now();
      fs.writeFileSync(path.join(DATA, 'google-calendar-cache.json'), JSON.stringify(gcalEvents));
    }
    if (acct && prefs.googleEventsPushOn) { await pushEvents(acct, store.doc.events, prefs.googlePushed); savePrefs(); }
    const tAcct = tasksAccount();
    if (tAcct && prefs.googleTasksOn) await syncTasks(tAcct, store);
    gcalError = null;
  } catch (e) { gcalError = e.message; }
  gcalBusy = false;
  broadcast('state-changed');
}
function googleOccurrences(start, end) {
  if (!prefs.googleCalendarOn || !calendarAccount()) return [];
  return gcalEvents.filter(e => (e.end > start && e.start < end) || (+e.start === +e.end && e.start >= start && e.start < end));
}

/** Tasks plus the numbers the tracker shows (computed here, where the tracking code lives). */
function decorate(t) {
  const now = new Date();
  return { ...t, _long: tracking.isLongTerm(t), _progress: tracking.progress(t), _pace: tracking.pace(t, now), _paceLabel: tracking.PACE_LABEL[tracking.pace(t, now)],
           _expected: tracking.expectedProgress(t, now), _remaining: tracking.remainingMinutes(t), _logged: tracking.loggedMinutes(t),
           _perDay: tracking.minutesPerDayNeeded(t, now), _next: tracking.nextMilestone(t), _grade: tracking.percentGrade(t) };
}
store.on('changed', () => {
  broadcast('state-changed');
  clearTimeout(syncTimer);
  syncTimer = setTimeout(syncNow, 2500);
  if (prefs.googleEventsPushOn || prefs.googleTasksOn) { clearTimeout(gcalTimer); gcalTimer = setTimeout(() => calendarNow(), 4000); }
});

// ---- IPC: what the windows can ask for ----
const handle = (ch, fn) => ipcMain.handle(ch, (_e, ...a) => fn(...a));

handle('state', () => ({
  tasks: store.tasks.map(decorate), plan: store.todayPlan, settings: store.doc.settings, courses: store.knownCourses, prefs,
  tracker: { courses: tracking.courseSummaries(store.tasks), workload: tracking.workloadPerDay(store.tasks) },
  calendar: { account: calendarAccount()?.email || null, connectable: [personal, school].filter(a => a.signedIn && !a.hasScope(CALENDAR[0])).map(a => ({ role: a === school ? 'school' : 'personal', email: a.email })),
              error: gcalError, busy: gcalBusy, lastRead: gcalRead || null },
  voice: { installed: voice.installed, sizeMB: voice.sizeMB, ...voice.status },
  google: { school: { signedIn: school.signedIn, email: school.email }, personal: { signedIn: personal.signedIn, email: personal.email },
            syncAccount: syncAccount()?.email || null, lastSync, syncError, lastClassroom, classroomError, syncing },
  claude: brain.claudePath,
}));
handle('occurrences', (start, end) => {
  const s0 = new Date(start), e0 = new Date(end), seen = new Set();
  return [...store.occurrencesIn(s0, e0), ...googleOccurrences(s0, e0)]
    .filter(o => { const k = `${o.title.toLowerCase()}|${Math.round(o.start / 60000)}|${o.isAllDay}`; if (seen.has(k)) return false; seen.add(k); return true; })
    .sort((a, b) => (a.isAllDay === b.isAllDay ? a.start - b.start : a.isAllDay ? -1 : 1));
});
handle('parse', text => store.parse(text));
handle('add', (text, kind) => (!kind && parseLog(text) ? store.applyLog(text) : store.add(store.parse(text), kind || undefined)));
handle('logPreview', text => store.logPreview(text));

// ---- One assignment, from its detail view ----
const editTask = (id, fn) => { const t0 = store.task(id); if (!t0) return null; const t = store.copy(t0); const r = fn(t); store.upsertTask(t); return r ?? null; };
handle('taskLog', (id, minutes) => editTask(id, t => { store.logWork(t, minutes, null, tracking.nextMilestone(t)?.id); return `Logged ${minutes}m · ${Math.round(tracking.progress(t) * 100)}% done`; }));
handle('taskSay', (id, text) => {
  const intent = parseLog(text) || parseLog('worked ' + text) || parseLog('finished ' + text);
  if (intent) return store.applyIntent(intent, id);
  return editTask(id, t => { store.logWork(t, 0, text, null); return 'Noted'; });
});
handle('stepToggle', (id, stepId) => editTask(id, t => {
  const m = t.milestones.find(x => x.id === stepId); if (!m) return;
  if (m.isDone) { m.isDone = false; m.doneAt = null; t.isCompleted = false; t.completedAt = null; } else store.finishStep(t, stepId);
}));
handle('stepAdd', (id, title) => editTask(id, t => {
  const last = t.milestones.at(-1)?.due || new Date();
  const due = new Date(Math.min(t.due || 8.64e15, new Date(last).getTime() + 86400e3));
  t.milestones.push({ id: require('./core/model').newId(), title, due, estimatedMinutes: 30, isDone: false });
}));
handle('stepUpdate', (id, stepId, patch) => editTask(id, t => { const m = t.milestones.find(x => x.id === stepId); if (m) Object.assign(m, patch.due ? { ...patch, due: new Date(patch.due) } : patch); }));
handle('stepDelete', (id, stepId) => editTask(id, t => { t.milestones = t.milestones.filter(x => x.id !== stepId); }));
handle('planSteps', id => editTask(id, t => { store.planSteps(t); }));
handle('setGrade', (id, earned, possible) => editTask(id, t => { t.pointsEarned = earned; t.maxPoints = possible || t.maxPoints || 100; }));
handle('markDone', id => editTask(id, t => { store.markDone(t); }));
handle('deleteSession', (id, sid) => editTask(id, t => { t.sessions = t.sessions.filter(x => x.id !== sid); t.actualMinutes = t.sessions.reduce((a, x) => a + x.minutes, 0); }));
handle('connectCalendar', async role => {
  const acct = role === 'school' ? school : personal;
  await acct.addScopes([...CALENDAR, TASKS]);
  prefs.googleCalendarOn = true; savePrefs();
  await calendarNow(true);
});
handle('calendarNow', () => calendarNow(true));
handle('upsertTask', t => store.upsertTask(t));
handle('toggleTask', id => store.toggleTask(id));
handle('deleteTask', id => store.deleteTask(id));
handle('upsertEvent', e => store.upsertEvent(e));
handle('deleteEvent', id => store.deleteEvent(id));
handle('checkIn', () => store.checkIn());
handle('startBlock', id => store.updateBlock(id, { startedAt: new Date() }));
handle('completeBlock', id => store.completeBlock(id));
handle('updateSettings', patch => store.updateSettings(patch));
handle('setPrefs', patch => {
  prefs = { ...prefs, ...patch }; savePrefs(); applyLoginItem(); broadcast('state-changed');
  if (['googleCalendarOn', 'googleEventsPushOn', 'googleTasksOn'].some(k => k in patch)) calendarNow(true);
});

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
  calendarNow();
  setInterval(syncNow, 90_000);
  setInterval(() => calendarNow(), 90_000);
  setInterval(() => school.signedIn && classroomNow(), 15 * 60_000);

  // `--snapshot <dir>`: save screenshots of both windows (for development), then quit.
  const snap = process.argv.indexOf('--snapshot');
  if (snap > 0) {
    const dir = process.argv[snap + 1];
    setTimeout(async () => {
      for (const [name, w, stage] of [['brain-today', brainWin, 'today'], ['brain-calendar', brainWin, 'calendar'], ['brain-assignments', brainWin, 'tasks'],
                                      ['brain-longterm', brainWin, 'tasks:long'], ['brain-classes', brainWin, 'tasks:classes'], ['brain-detail', brainWin, 'detail'], ['brain-settings', brainWin, 'settings']]) {
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
