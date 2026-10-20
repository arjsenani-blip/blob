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
  hasScope(s) { return (this.tokens?.scope || '').includes(s); }

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
                                         code_challenge: challenge, code_challenge_method: 'S256', access_type: 'offline', prompt: 'consent select_account' });
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
    if (res.status < 200 || res.status >= 300) throw new Error(`Google error ${res.status}`);
    return res.body;
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
  const courses = await pages(account, 'https://classroom.googleapis.com/v1/courses?studentId=me&courseStates=ACTIVE&pageSize=100', 'courses');
  const oldest = Date.now() - 21 * 86400e3;
  let added = 0;
  for (const c of courses) {
    const base = `https://classroom.googleapis.com/v1/courses/${c.id}`;
    const [works, subs] = await Promise.all([
      pages(account, base + '/courseWork?courseWorkStates=PUBLISHED&orderBy=dueDate%20desc&pageSize=60', 'courseWork'),
      pages(account, base + '/courseWork/-/studentSubmissions?userId=me&pageSize=100', 'studentSubmissions'),
    ]);
    const turnedIn = new Set(subs.filter(s => ['TURNED_IN', 'RETURNED'].includes(s.state)).map(s => s.courseWorkId));
    for (const w of works) {
      let due = null;
      if (w.dueDate?.year) {
        due = w.dueTime ? new Date(Date.UTC(w.dueDate.year, w.dueDate.month - 1, w.dueDate.day, w.dueTime.hours || 0, w.dueTime.minutes || 0))
                        : new Date(w.dueDate.year, w.dueDate.month - 1, w.dueDate.day, 23, 59);
      }
      if (due && due < oldest) continue;
      if (!due && w.creationTime && new Date(w.creationTime) < oldest) continue;
      const externalID = `${c.id}:${w.id}`, id = stableId('classroom:' + externalID);
      const done = turnedIn.has(w.id);
      const existing = store.task(id);
      if (existing) {
        const next = { ...existing, title: w.title || 'Untitled', course: c.name, due, link: w.alternateLink || null };
        if (done && !existing.isCompleted) Object.assign(next, { isCompleted: true, completedAt: new Date() });
        if (JSON.stringify({ ...next, updatedAt: 0 }) !== JSON.stringify({ ...existing, updatedAt: 0 })) store.upsertTask(next);
      } else if (!(done && (!due || due < new Date()))) {
        const [mins, difficulty] = estimate({ title: w.title || '', workType: w.workType, maxPoints: w.maxPoints });
        store.upsertTask(newTask({ id, title: w.title || 'Untitled', course: c.name, notes: w.description || null, due, estimatedMinutes: mins, difficulty,
                                   source: 'classroom', externalID, link: w.alternateLink || null, isCompleted: done }));
        added++;
      }
    }
  }
  return added;
}

module.exports = { GoogleAccount, syncDrive, syncClassroom, CLASSROOM, DRIVE };
