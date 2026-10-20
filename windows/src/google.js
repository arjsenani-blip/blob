// Google on Windows: sign-in (desktop OAuth with PKCE), Mac/iPhone sync through Drive's hidden app folder,
// and read-only Google Classroom assignments — the same data and file the Swift apps use.
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const crypto = require('crypto');
const { shell, safeStorage } = require('electron');
const { decodeDoc, encodeDoc, stableId, task: newTask } = require('./core/model');

const CLASSROOM = ['https://www.googleapis.com/auth/classroom.courses.readonly', 'https://www.googleapis.com/auth/classroom.coursework.me.readonly'];
const DRIVE = 'https://www.googleapis.com/auth/drive.appdata';
// Read your calendars and write Blob's own events; assignments as Google Tasks (shown as tasks in Google Calendar).
const CALENDAR = ['https://www.googleapis.com/auth/calendar.events', 'https://www.googleapis.com/auth/calendar.calendarlist.readonly'];
const TASKS = 'https://www.googleapis.com/auth/tasks';
const FILE_NAME = 'arjuns-brain.json';

function request(method, url, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request({ method, hostname: u.hostname, path: u.pathname + u.search, headers }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

class GoogleAccount {
  constructor(dir, role, getConfig) {
    this.file = path.join(dir, `google-${role}.bin`);
    this.getConfig = getConfig;            // () => ({ clientId, clientSecret })
    this.tokens = null;
    try {
      const raw = fs.readFileSync(this.file);
      this.tokens = JSON.parse(safeStorage.isEncryptionAvailable() ? safeStorage.decryptString(raw) : raw.toString());
    } catch { /* not signed in */ }
  }

  get signedIn() { return !!this.tokens?.refresh_token; }
  get email() { return this.tokens?.email || null; }
  hasScope(s) { return (this.tokens?.scope || '').split(' ').includes(s); }
  get grantedScopes() { return (this.tokens?.scope || '').split(' ').filter(x => x.startsWith('https://')); }
  /** Ask for more access, keeping what's already granted. */
  addScopes(scopes) { return this.signIn([...new Set([...this.grantedScopes, ...scopes])]); }

  save(t) {
    this.tokens = t;
    const data = JSON.stringify(t);
    fs.writeFileSync(this.file, safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(data) : data);
  }

  signOut() {
    if (this.tokens?.refresh_token) request('POST', `https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(this.tokens.refresh_token)}`).catch(() => {});
    this.tokens = null;
    fs.rmSync(this.file, { force: true });
  }

  /** Opens Google sign-in in the browser and waits for it to come back to a local port. */
  async signIn(scopes) {
    const { clientId, clientSecret } = this.getConfig();
    if (!clientId) throw new Error('Add your Google OAuth client ID in Settings first.');
    const verifier = crypto.randomBytes(48).toString('base64url');
    const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
    const server = http.createServer();
    await new Promise(r => server.listen(0, '127.0.0.1', r));
    const redirect = `http://127.0.0.1:${server.address().port}`;
    const params = new URLSearchParams({ client_id: clientId, redirect_uri: redirect, response_type: 'code', scope: ['openid', 'email', ...scopes].join(' '),
                                         code_challenge: challenge, code_challenge_method: 'S256', access_type: 'offline', prompt: 'consent select_account',
                                         include_granted_scopes: 'true' });
    const code = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { server.close(); reject(new Error('Sign-in timed out.')); }, 5 * 60e3);
      server.on('request', (req, res) => {
        const q = new URL(req.url, redirect).searchParams;
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end('<body style="font-family:system-ui;background:#06121f;color:#bff;display:grid;place-items:center;height:100vh"><h2>You\'re signed in — you can close this tab and go back to Blob.</h2></body>');
        clearTimeout(timeout); server.close();
        q.get('code') ? resolve(q.get('code')) : reject(new Error(q.get('error') || 'Sign-in was cancelled.'));
      });
      shell.openExternal(`https://accounts.google.com/o/oauth2/v2/auth?${params}`);
    });
    const tok = await this.tokenRequest({ code, client_id: clientId, client_secret: clientSecret || '', redirect_uri: redirect, grant_type: 'authorization_code', code_verifier: verifier });
    if (!tok.refresh_token) throw new Error('Google did not return a refresh token.');
    let email = null;
    try { email = JSON.parse(Buffer.from(tok.id_token.split('.')[1], 'base64url').toString()).email; } catch { /* optional */ }
    this.save({ ...tok, email, expiry: Date.now() + (tok.expires_in - 60) * 1000 });
  }

  async tokenRequest(form) {
    const res = await request('POST', 'https://oauth2.googleapis.com/token', { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(form).toString() });
    const json = JSON.parse(res.body || '{}');
    if (res.status !== 200) {
      if (form.grant_type === 'refresh_token') { this.signOut(); throw new Error('Please sign in to Google again.'); }
      throw new Error(json.error_description || json.error || `Google error ${res.status}`);
    }
    return json;
  }

  async accessToken() {
    if (!this.signedIn) throw new Error('Sign in with Google first.');
    if (this.tokens.expiry > Date.now()) return this.tokens.access_token;
    const { clientId, clientSecret } = this.getConfig();
    const t = await this.tokenRequest({ client_id: clientId, client_secret: clientSecret || '', refresh_token: this.tokens.refresh_token, grant_type: 'refresh_token' });
    this.save({ ...this.tokens, access_token: t.access_token, expiry: Date.now() + (t.expires_in - 60) * 1000 });
    return t.access_token;
  }

  async api(method, url, opts = {}) {
    const headers = { Authorization: `Bearer ${await this.accessToken()}`, ...(opts.headers || {}) };
    const res = await request(method, url, { ...opts, headers });
    if (res.status === 403 && /admin|policy|access_denied/.test(res.body)) throw new Error('Your school\'s Google admin is blocking this app. Use a personal account for sync.');
    if (res.status < 200 || res.status >= 300) {
      let msg = ''; try { msg = JSON.parse(res.body).error?.message || ''; } catch { /* plain */ }
      const e = new Error(`Google error ${res.status}${msg ? ': ' + msg : ''}`); e.status = res.status; throw e;
    }
    return res.body;
  }
  json(method, url, body) {
    return this.api(method, url, body ? { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {});
  }
}

// ---- Mac/iPhone/Windows sync through Drive's hidden app folder ----
async function syncDrive(account, store) {
  const list = JSON.parse(await account.api('GET', `https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&q=${encodeURIComponent(`name = '${FILE_NAME}'`)}&fields=files(id,modifiedTime)&orderBy=modifiedTime%20desc`));
  const fileId = list.files?.[0]?.id;
  let remoteRaw = null;
  if (fileId) {
    remoteRaw = await account.api('GET', `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`);
    const remote = decodeDoc(remoteRaw);
    if (remote.schemaVersion > 1) throw new Error('Another device has a newer version of Blob. Update this one.');
    store.mergeRemote(remote);
  }
  const out = encodeDoc(store.doc);
  if (out === remoteRaw) return;
  if (fileId) {
    await account.api('PATCH', `https://www.googleapis.com/upload/drive/v3/files/${fileId}?uploadType=media`, { headers: { 'Content-Type': 'application/json' }, body: out });
  } else {
    const boundary = 'blob-' + crypto.randomUUID();
    const body = `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify({ name: FILE_NAME, parents: ['appDataFolder'], mimeType: 'application/json' })}\r\n`
      + `--${boundary}\r\nContent-Type: application/json\r\n\r\n${out}\r\n--${boundary}--`;
    await account.api('POST', 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart', { headers: { 'Content-Type': `multipart/related; boundary=${boundary}` }, body });
  }
}

// ---- Google Classroom (read-only) ----
async function pages(account, base, key) {
  const out = []; let token = null;
  do {
    const json = JSON.parse(await account.api('GET', base + (token ? `&pageToken=${token}` : '')));
    out.push(...(json[key] || [])); token = json.nextPageToken;
  } while (token && out.length < 500);
  return out;
}

function estimate(item) {
  const t = item.title.toLowerCase(), has = (...w) => w.some(x => t.includes(x));
  if (['MULTIPLE_CHOICE_QUESTION', 'SHORT_ANSWER_QUESTION'].includes(item.workType)) return [15, 1];
  if (has('essay', 'research', 'project', 'lab report', 'presentation', 'paper')) return [90, 3];
  if (has('test', 'exam', 'study guide', 'review')) return [60, 3];
  if (has('quiz', 'exit ticket', 'warm up', 'warm-up', 'bell ringer')) return [20, 1];
  if (has('reading', 'read ', 'chapter', 'notes')) return [30, 2];
  if (has('worksheet', 'practice', 'problem', 'hw', 'homework')) return [35, 2];
  if ((item.maxPoints || 0) >= 100) return [60, 3];
  return [40, 2];
}

async function syncClassroom(account, store) {
  const tracking = require('./core/tracking');
  const courses = await pages(account, 'https://classroom.googleapis.com/v1/courses?studentId=me&courseStates=ACTIVE&pageSize=100', 'courses');
  // Far enough back to cover the semester, so grades and finished work build up a history.
  const oldest = Date.now() - 150 * 86400e3;
  let added = 0, graded = 0;
  for (const c of courses) {
    const base = `https://classroom.googleapis.com/v1/courses/${c.id}`;
    const [works, subs] = await Promise.all([
      pages(account, base + '/courseWork?courseWorkStates=PUBLISHED&orderBy=dueDate%20desc&pageSize=100', 'courseWork'),
      pages(account, base + '/courseWork/-/studentSubmissions?userId=me&pageSize=100', 'studentSubmissions'),
    ]);
    const subBy = Object.fromEntries(subs.map(s => [s.courseWorkId, s]));
    for (const w of works) {
      let due = null;
      if (w.dueDate?.year) {
        due = w.dueTime ? new Date(Date.UTC(w.dueDate.year, w.dueDate.month - 1, w.dueDate.day, w.dueTime.hours || 0, w.dueTime.minutes || 0))
                        : new Date(w.dueDate.year, w.dueDate.month - 1, w.dueDate.day, 23, 59);
      }
      const assigned = w.creationTime ? new Date(w.creationTime) : null;
      if (due && due < oldest) continue;
      if (!due && assigned && assigned < oldest) continue;
      const sub = subBy[w.id] || {};
      const turnedIn = ['TURNED_IN', 'RETURNED'].includes(sub.state);
      const grade = typeof sub.assignedGrade === 'number' ? sub.assignedGrade : null;
      const externalID = `${c.id}:${w.id}`, id = stableId('classroom:' + externalID);
      const existing = store.task(id);
      if (existing) {
        const next = store.copy(existing);
        Object.assign(next, { title: w.title || 'Untitled', course: c.name, due, link: w.alternateLink || null,
                              maxPoints: w.maxPoints ?? existing.maxPoints ?? null, submissionState: sub.state || null, isLate: !!sub.late });
        if (!next.startDate) next.startDate = assigned;
        if (grade != null && existing.pointsEarned !== grade) { next.pointsEarned = grade; graded++; }
        if (turnedIn && !existing.isCompleted) store.markDone(next);
        if (sub.state === 'RECLAIMED_BY_STUDENT' && existing.isCompleted) { next.isCompleted = false; next.completedAt = null; }
        if (JSON.stringify({ ...next, updatedAt: 0 }) !== JSON.stringify({ ...existing, updatedAt: 0 })) store.upsertTask(next);
      } else {
        const finished = turnedIn || grade != null;
        // Old finished work is kept only when it has a grade — that's your grade history.
        if (finished && (!due || due < new Date()) && grade == null) continue;
        if (!finished && due && due < Date.now() - 21 * 86400e3) continue;
        const [mins, difficulty] = estimate({ title: w.title || '', workType: w.workType, maxPoints: w.maxPoints });
        store.upsertTask(newTask({ id, title: w.title || 'Untitled', course: c.name, notes: w.description || null, due, estimatedMinutes: mins, difficulty,
                                   source: 'classroom', externalID, link: w.alternateLink || null, isCompleted: finished,
                                   completedAt: finished ? (due || new Date()) : null, startDate: assigned, createdAt: assigned || new Date(),
                                   pointsEarned: grade, maxPoints: w.maxPoints ?? null, submissionState: sub.state || null, isLate: !!sub.late }));
        if (!finished) {
          added++;
          if (tracking.looksLongTerm(w.title || '', due) || ((w.maxPoints || 0) >= 100 && due && due - Date.now() > 5 * 86400e3)) store.setUpLongTerm(id, true);
        }
      }
    }
  }
  return { added, graded };
}

// ---- Google Calendar ----

/** The calendars you have turned on in Google Calendar, as read-only occurrences (Blob's own events skipped). */
async function fetchCalendarEvents(account, from, to) {
  const list = JSON.parse(await account.api('GET', 'https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=100'));
  const cals = (list.items || []).filter(c => c.selected ?? c.accessRole === 'owner');
  const out = [];
  for (const c of cals) {
    let token = null;
    do {
      const url = `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(c.id)}/events?singleEvents=true&orderBy=startTime&maxResults=250`
        + `&timeMin=${encodeURIComponent(from.toISOString())}&timeMax=${encodeURIComponent(to.toISOString())}` + (token ? `&pageToken=${token}` : '');
      const page = JSON.parse(await account.api('GET', url));
      for (const e of page.items || []) {
        if (e.status === 'cancelled' || e.id.startsWith('blob') || e.extendedProperties?.private?.blob) continue;
        const day = s => { const [y, m, d] = s.split('-').map(Number); return new Date(y, m - 1, d); };
        let start, end, allDay = false;
        if (e.start?.dateTime) { start = new Date(e.start.dateTime); end = e.end?.dateTime ? new Date(e.end.dateTime) : new Date(start.getTime() + 3600e3); }
        else if (e.start?.date) { allDay = true; start = day(e.start.date); end = e.end?.date ? day(e.end.date) : new Date(start.getTime() + 86400e3); }
        else continue;
        out.push({ id: `gcal:${e.id}@${Math.floor(start / 1000)}`, eventID: null, title: e.summary || 'Busy', start, end, isAllDay: allDay,
                   location: e.location || null, externalCalendar: c.summary || 'Google Calendar', colorHex: c.backgroundColor || null });
      }
      token = page.nextPageToken;
    } while (token && out.length < 3000);
  }
  return out;
}

/** Google accepts our own event ids, so each Blob event has exactly one Google twin (no duplicates across devices). */
const googleId = id => 'blob' + id.toLowerCase().replace(/-/g, '');

function eventBody(ev) {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const pad = n => String(n).padStart(2, '0');
  const ymd = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const local = d => `${ymd(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}:00`;
  const b = { id: googleId(ev.id), summary: ev.title, extendedProperties: { private: { blob: ev.id } }, source: { title: 'Blob', url: 'https://github.com/arjsenani-blip/blob' } };
  if (ev.location) b.location = ev.location;
  if (ev.notes) b.description = ev.notes;
  if (ev.isAllDay) {
    const s = new Date(ev.start.getFullYear(), ev.start.getMonth(), ev.start.getDate());
    const e = new Date(Math.max(new Date(ev.end.getFullYear(), ev.end.getMonth(), ev.end.getDate()), s.getTime() + 86400e3));
    b.start = { date: ymd(s) }; b.end = { date: ymd(e) };
  } else {
    b.start = { dateTime: local(ev.start), timeZone: tz };
    b.end = { dateTime: local(new Date(Math.max(ev.end, ev.start.getTime() + 60e3))), timeZone: tz };
  }
  const r = ev.recurrence || {}, DAYS = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
  let rule = null;
  if (r.frequency === 'daily') rule = 'RRULE:FREQ=DAILY';
  else if (r.frequency === 'weekdays') rule = 'RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
  else if (r.frequency === 'monthly') rule = 'RRULE:FREQ=MONTHLY';
  else if (r.frequency === 'weekly') rule = 'RRULE:FREQ=WEEKLY;BYDAY=' + (r.weekdays?.length ? [...r.weekdays].sort() : [ev.start.getDay() + 1]).map(w => DAYS[w - 1]).join(',');
  if (rule) {
    if (r.until) { const u = new Date(r.until); u.setHours(23, 59, 59); rule += ';UNTIL=' + u.toISOString().replace(/[-:]/g, '').replace(/\.\d+/, ''); }
    const lines = [rule];
    if (ev.excludedDays?.length) {
      const stamps = ev.excludedDays.map(d => { const x = new Date(d); x.setHours(ev.start.getHours(), ev.start.getMinutes(), 0); return ev.isAllDay ? ymd(x).replace(/-/g, '') : local(x).replace(/[-:]/g, ''); });
      lines.push(ev.isAllDay ? 'EXDATE;VALUE=DATE:' + stamps.join(',') : `EXDATE;TZID=${tz}:` + stamps.join(','));
    }
    b.recurrence = lines;
  }
  return b;
}

/** Push events changed since the last push. `pushed`: {eventId: updatedAt ms last sent}. */
async function pushEvents(account, events, pushed) {
  const base = 'https://www.googleapis.com/calendar/v3/calendars/primary/events';
  for (const ev of events) {
    const stamp = +ev.updatedAt;
    if (pushed[ev.id] >= stamp) continue;
    const gid = googleId(ev.id);
    if (ev.deleted) {
      if (pushed[ev.id] != null) await account.api('DELETE', `${base}/${gid}`).catch(e => { if (![404, 410].includes(e.status)) throw e; });
      pushed[ev.id] = stamp; continue;
    }
    const body = eventBody(ev);
    try { await account.json('PUT', `${base}/${gid}`, body); }
    catch (e) {
      if (e.status !== 404) throw e;
      try { await account.json('POST', base, body); }
      catch (e2) { if (e2.status !== 409) throw e2; await account.json('PUT', `${base}/${gid}`, { ...body, status: 'confirmed' }); }
    }
    pushed[ev.id] = stamp;
  }
}

// ---- Assignments → Google Tasks ----

async function syncTasks(account, store) {
  const lists = JSON.parse(await account.api('GET', 'https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100'));
  let listId = (lists.items || []).find(l => l.title === 'Blob')?.id;
  if (!listId) listId = JSON.parse(await account.json('POST', 'https://tasks.googleapis.com/tasks/v1/users/@me/lists', { title: 'Blob' })).id;
  const base = `https://tasks.googleapis.com/tasks/v1/lists/${encodeURIComponent(listId)}/tasks`;
  const existing = {};
  let token = null;
  do {
    const page = JSON.parse(await account.api('GET', `${base}?showCompleted=true&showHidden=true&maxResults=100` + (token ? `&pageToken=${token}` : '')));
    for (const g of page.items || []) {
      if (g.deleted) continue;
      const key = (g.notes || '').split('\n').pop();
      if (!key.startsWith('blob://task/')) continue;
      if (existing[key]) { await account.api('DELETE', `${base}/${g.id}`).catch(() => {}); continue; }
      existing[key] = g;
    }
    token = page.nextPageToken;
  } while (token);

  const tracking = require('./core/tracking');
  const recent = Date.now() - 14 * 86400e3;
  const result = { completed: 0 };
  const wanted = new Set();
  for (const t of store.doc.tasks) {
    const key = `blob://task/${t.id}`;
    if (t.deleted || (t.isCompleted && !(t.completedAt > recent))) continue;
    wanted.add(key);
    const g = existing[key];
    const gDone = g?.status === 'completed';
    if (g && gDone !== t.isCompleted && new Date(g.updated) > new Date(+t.updatedAt + 1000)) {
      // Ticked off (or reopened) in Google Calendar / Tasks after Blob last changed it.
      const c = store.copy(t);
      if (gDone) { store.markDone(c); result.completed++; } else { c.isCompleted = false; c.completedAt = null; }
      store.upsertTask(c);
      continue;
    }
    const notes = [t.course, tracking.isLongTerm(t) && !t.isCompleted
      ? `${Math.round(tracking.progress(t) * 100)}% done · ${tracking.PACE_LABEL[tracking.pace(t)]}` + (tracking.nextMilestone(t) ? ` · next: ${tracking.nextMilestone(t).title}` : '') : null, key]
      .filter(Boolean).join('\n');
    const body = { title: t.title, notes, status: t.isCompleted ? 'completed' : 'needsAction' };
    if (t.due) { const p = n => String(n).padStart(2, '0'); body.due = `${t.due.getFullYear()}-${p(t.due.getMonth() + 1)}-${p(t.due.getDate())}T00:00:00.000Z`; }
    if (g) {
      const same = g.title === body.title && g.notes === body.notes && gDone === t.isCompleted && (g.due || '').slice(0, 10) === (body.due || '').slice(0, 10);
      if (!same) await account.json('PATCH', `${base}/${g.id}`, body);
    } else if (!t.isCompleted) await account.json('POST', base, body);
  }
  for (const [key, g] of Object.entries(existing)) if (!wanted.has(key)) await account.api('DELETE', `${base}/${g.id}`).catch(() => {});
  return result;
}

module.exports = { GoogleAccount, syncDrive, syncClassroom, fetchCalendarEvents, pushEvents, syncTasks, eventBody, CLASSROOM, DRIVE, CALENDAR, TASKS };
