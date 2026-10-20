// Blob's Brain — the planner window on Windows: Today (check-in timeline), Calendar, Assignments, Settings.
'use strict';
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const PALETTE = ['#785cff', '#219ffa', '#1abd8f', '#ff9e1a', '#ff619e', '#f24d4d', '#00b3cc', '#a970f2'];
function colorFor(key) {
  if (!key) return PALETTE[0];
  let h = 5381; for (const ch of key.toLowerCase()) h = ((h * 33) + ch.charCodeAt(0)) >>> 0;
  return PALETTE[h % PALETTE.length];
}
const time = d => new Date(d).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
const sod = d => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; };
const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
function dueText(d, withTime = true) {
  d = new Date(d);
  const days = Math.round((sod(d) - sod(new Date())) / 86400000), t = withTime ? ' ' + time(d) : '';
  if (days === 0) return 'Today' + t;
  if (days === 1) return 'Tomorrow' + t;
  if (days === -1) return 'Yesterday' + t;
  if (days > 0 && days < 7) return d.toLocaleDateString([], { weekday: 'short' }) + t;
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + t;
}
const durationText = m => { const h = Math.floor(m / 60), r = m % 60; return h === 0 ? `${r}m` : r === 0 ? `${h}h` : `${h}h ${r}m`; };
const chip = (text, c = '#785cff', icon = '') => `<span class="chip" style="--c:${c}">${icon ? icon + ' ' : ''}${esc(text)}</span>`;
function toast(msg) { const t = $('#toast'); t.textContent = msg; t.classList.remove('hidden'); clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.add('hidden'), 2200); }

let tab = 'today', state = null, selected = sod(new Date()), month = new Date(new Date().getFullYear(), new Date().getMonth(), 1), showDone = false;
BlobArt.animateBlob($('#miniblob'), { still: true });

document.querySelectorAll('nav button').forEach(b => b.addEventListener('click', () => go(b.dataset.tab)));
function go(t) { tab = t; document.querySelectorAll('nav button').forEach(b => b.classList.toggle('on', b.dataset.tab === t)); render(); }
blob.onState(() => refresh());
blob.onStage(t => go(t));

async function refresh() { state = await blob.state(); render(); }

async function render() {
  if (!state) return;
  const g = state.google;
  $('#syncbadge').textContent = g.syncing ? '⟳ Syncing…' : g.syncError ? '⚠ Sync problem' : g.syncAccount ? `☁ Synced${g.lastSync ? ' ' + time(g.lastSync) : ''}` : '☁ Sync off';
  const main = $('#main');
  const scroll = main.scrollTop;
  if (tab === 'today') main.innerHTML = await today();
  if (tab === 'calendar') main.innerHTML = await calendar();
  if (tab === 'tasks') main.innerHTML = tasksView();
  if (tab === 'settings') main.innerHTML = settings();
  main.scrollTop = scroll;
  wire();
}

// ---------------------------------------------------------------- quick add (shared by Today and Calendar)
const quickAdd = () => `<div class="card"><div class="quick"><span class="spark">✨</span>
  <input id="qa" placeholder="Try “Essay due friday ~90m” or “Soccer every tue 5-7pm @ Lincoln Field”" autocomplete="off"></div>
  <div id="qaprev" class="preview chips"></div></div>`;
let qaKind = null;
async function previewQuickAdd() {
  const text = $('#qa').value.trim(), box = $('#qaprev');
  if (!text) { box.innerHTML = ''; qaKind = null; return; }
  const p = await blob.parse(text);
  const kind = qaKind || p.kind;
  const parts = [`<span class="chip" style="--c:${kind === 'event' ? '#785cff' : '#ff619e'};cursor:pointer" id="kindchip">${kind === 'event' ? '📅 Event' : '✅ To-do'} ⇄</span>`, chip(p.title || 'Untitled', '#888')];
  if (p.start) {
    if (kind === 'task') parts.push(chip('Due ' + dueText(p.start, p.hasExplicitTime), '#ff9e1a', '⚑'));
    else if (p.isAllDay) parts.push(chip(dueText(p.start, false) + ' · all day', '#219ffa', '📅'));
    else parts.push(chip(`${dueText(p.start, false)} ${time(p.start)}${p.end ? ' – ' + time(p.end) : ''}`, '#219ffa', '🕒'));
  }
  if (p.recurrence?.frequency && p.recurrence.frequency !== 'none') parts.push(chip('Repeats ' + p.recurrence.frequency, '#14b8a6', '🔁'));
  if (p.location) parts.push(chip(p.location, '#22c55e', '📍'));
  if (p.course && kind === 'task') parts.push(chip(p.course, colorFor(p.course), '🎓'));
  if (p.tag) parts.push(chip('#' + p.tag, colorFor(p.tag)));
  if (kind === 'task' && p.durationMinutes) parts.push(chip(durationText(p.durationMinutes), '#a970f2', '⏱'));
  box.innerHTML = parts.join('');
  $('#kindchip').onclick = () => { qaKind = kind === 'event' ? 'task' : 'event'; previewQuickAdd(); };
}

// ---------------------------------------------------------------- Today
async function today() {
  const now = new Date();
  const hr = now.getHours();
  const greet = hr >= 4 && hr < 12 ? 'Good morning' : hr < 17 && hr >= 12 ? 'Good afternoon' : hr >= 17 && hr < 22 ? 'Good evening' : 'Late night';
  const occ = await blob.occurrences(sod(now), addDays(sod(now), 1));
  const pending = state.tasks.filter(t => !t.isCompleted);
  const dueToday = pending.filter(t => t.due && new Date(t.due) < addDays(sod(now), 1)).length;
  const eventsLeft = occ.filter(o => !o.isAllDay && new Date(o.end) > now).length;
  const plan = state.plan;
  let planHtml;
  if (plan) {
    const blocks = plan.blocks.map((b, i) => {
      const last = i === plan.blocks.length - 1;
      const task = b.taskID && state.tasks.find(t => t.id === b.taskID);
      const done = b.isDone || task?.isCompleted;
      const isNow = new Date(b.start) <= now && now < new Date(b.end) && !done;
      const c = b.kind === 'task' ? colorFor(b.subtitle || b.title) : b.kind === 'event' ? '#8b8b96' : '#14b8a6';
      let body;
      if (b.kind === 'breakTime') body = `<div class="breakrow">☕ Break · ${Math.round((new Date(b.end) - new Date(b.start)) / 60000)} min</div>`;
      else if (b.kind === 'event') body = `<div><b>📅 ${esc(b.title)}</b><div class="small muted">${time(b.start)} – ${time(b.end)}${b.subtitle ? ' · ' + esc(b.subtitle) : ''}</div></div>`;
      else body = `<div class="task ${isNow ? 'now' : ''}" style="--c:${c}"><div class="row" style="justify-content:space-between">
          <div><div class="t">${esc(b.title)}${b.part ? ` (${b.part}/${b.partsTotal})` : ''}</div>
            <div class="chips" style="margin-top:4px">${b.subtitle ? chip(b.subtitle, c) : ''}${chip(Math.round((new Date(b.end) - new Date(b.start)) / 60000) + ' min', '#888', '⏱')}${isNow ? chip('Now', '#785cff', '⚡') : ''}</div></div>
          <div class="row">${done ? '✅' : `${b.startedAt ? `<span class="small muted">started ${time(b.startedAt)}</span>` : `<button class="btn small" data-start="${b.id}">▶</button>`}<button class="btn small primary" data-done="${b.id}">✓</button>`}</div></div>
          ${b.reason ? `<div class="small muted" style="margin-top:6px">${esc(b.reason)}</div>` : ''}</div>`;
      return `<div class="block ${done ? 'done' : ''}"><div class="time">${time(b.start)}</div><div class="rail"><div class="dotc" style="--c:${done ? '#22c55e' : c}"></div>${last ? '' : '<div class="line"></div>'}</div><div class="body">${body}</div></div>`;
    }).join('');
    const overflow = plan.overflowTaskIDs.map(id => state.tasks.find(t => t.id === id)).filter(t => t && !t.isCompleted);
    planHtml = `<div><div class="row" style="justify-content:space-between"><div><h2 style="margin:0">Your timeline</h2><div class="muted small">${esc(plan.summary)}</div></div>
      <button class="btn" id="checkin">⟳ Re-check in</button></div>
      <div class="small muted" style="margin:10px 0;padding:10px;border-radius:12px;background:color-mix(in srgb, #785cff 8%, transparent)">💡 ${esc(plan.strategy)}</div>
      <div class="card timeline">${blocks || '<div class="muted">Nothing to do. Seriously — go have fun.</div>'}</div>
      ${overflow.length ? `<div class="card" style="margin-top:12px"><b style="color:#ff9e1a">🌙 Didn't fit before bedtime</b>${overflow.map(taskRow).join('')}</div>` : ''}</div>`;
  } else {
    planHtml = `<div class="card"><div class="row"><canvas id="checkblob" style="width:64px;height:64px"></canvas><div><h2 style="margin:0 0 4px">Ready to get to work?</h2>
      <div class="muted">Check in and Blob lines up your assignments in the best order for right now — around your events, with breaks, done by bedtime.</div></div></div>
      <button class="btn primary" id="checkin" style="width:100%;margin-top:14px">▶ Check in now · ${time(now)}</button></div>`;
  }
  const due = state.tasks.filter(t => t.due && sod(new Date(t.due)).getTime() === sod(now).getTime());
  const agenda = occ.map(agendaRow).join('') + due.map(taskRow).join('');
  return `<div class="page"><div><div class="date">${now.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })}</div>
    <h1>${greet}, ${esc(state.prefs.name)}</h1>
    <div class="chips" style="margin-top:8px">${chip(`${dueToday} due today`, dueToday ? '#ff9e1a' : '#22c55e', '⚑')}${chip(`${eventsLeft} events left`, '#219ffa', '📅')}${chip(`${pending.length} open to-dos`, '#ff619e', '✅')}</div></div>
    ${quickAdd()}${planHtml}
    <div><h2>On the calendar</h2><div class="card">${agenda || '<div class="muted">☀️ Nothing scheduled today.</div>'}</div></div></div>`;
}

function agendaRow(o) {
  return `<div class="agenda-row"><div class="small" style="text-align:right">${o.isAllDay ? 'all day' : `<b>${time(o.start)}</b><br><span class="muted">${time(o.end)}</span>`}</div>
    <div class="bar" style="--c:${colorFor(o.tag || o.title)}"></div><div><b>${esc(o.title)}</b>${o.location ? `<div class="small muted">${esc(o.location)}</div>` : ''}</div>
    <button class="btn small danger" data-delevent="${o.eventID}" title="Delete event">✕</button></div>`;
}

function taskRow(t) {
  const overdue = !t.isCompleted && t.due && new Date(t.due) < new Date();
  return `<div class="tasks-row"><button class="check ${t.isCompleted ? 'on' : ''}" style="--c:${colorFor(t.course)}" data-toggle="${t.id}"></button>
    <div><div class="t" style="${t.isCompleted ? 'text-decoration:line-through;opacity:.6' : ''}">${esc(t.title)}</div>
      <div class="chips" style="margin-top:3px">${t.course ? chip(t.course, colorFor(t.course)) : ''}${t.due ? chip(dueText(t.due), overdue ? '#e5484d' : '#ff9e1a', overdue ? '⚠' : '⚑') : ''}${chip(durationText(t.estimatedMinutes), '#888', '⏱')}</div></div>
    <div class="row">${t.source === 'classroom' ? '<span title="From Google Classroom">🎓</span>' : ''}<button class="btn small danger" data-deltask="${t.id}" title="Delete">✕</button></div></div>`;
}

// ---------------------------------------------------------------- Calendar
async function calendar() {
  const first = new Date(month), lead = first.getDay();
  const days = Array.from({ length: 42 }, (_, i) => addDays(first, i - lead));
  const occ = await blob.occurrences(days[0], addDays(days[41], 1));
  const byDay = {}; occ.forEach(o => (byDay[sod(new Date(o.start)).getTime()] ||= []).push(o));
  const dueBy = {}; state.tasks.filter(t => t.due && !t.isCompleted).forEach(t => (dueBy[sod(new Date(t.due)).getTime()] ||= []).push(t));
  const cells = days.map(d => {
    const k = d.getTime(), dots = (byDay[k] || []).slice(0, 3).map(o => `<i style="--c:${colorFor(o.tag || o.title)}"></i>`).join('') + ((dueBy[k] || []).length ? '<i style="--c:#ff9e1a;border-radius:1px"></i>' : '');
    return `<button class="day ${d.getMonth() !== first.getMonth() ? 'out' : ''} ${k === sod(new Date()).getTime() ? 'today' : ''} ${k === selected.getTime() ? 'sel' : ''}" data-day="${k}"><div class="n">${d.getDate()}</div><div class="dots">${dots}</div></button>`;
  }).join('');
  const dayOcc = byDay[selected.getTime()] || [];
  const dayDue = state.tasks.filter(t => t.due && sod(new Date(t.due)).getTime() === selected.getTime());
  return `<div class="page" style="max-width:1000px">${quickAdd()}<div class="cal">
    <div class="card"><div class="row" style="justify-content:space-between;margin-bottom:10px"><h2 style="margin:0">${first.toLocaleDateString([], { month: 'long', year: 'numeric' })}</h2>
      <div class="row"><button class="btn small" id="prevm">‹</button><button class="btn small" id="todaym">Today</button><button class="btn small" id="nextm">›</button></div></div>
      <div class="month">${['S', 'M', 'T', 'W', 'T', 'F', 'S'].map(w => `<div class="wd">${w}</div>`).join('')}${cells}</div></div>
    <div class="card"><h2>${selected.toLocaleDateString([], { weekday: 'long', month: 'short', day: 'numeric' })}</h2>
      ${dayOcc.map(agendaRow).join('') || (dayDue.length ? '' : '<div class="muted">Free day. Type above to add something.</div>')}
      ${dayDue.length ? `<div class="group">DUE</div>${dayDue.map(taskRow).join('')}` : ''}</div></div></div>`;
}

// ---------------------------------------------------------------- Assignments
function tasksView() {
  const now = new Date(), t0 = sod(now), t1 = addDays(t0, 1), t2 = addDays(t0, 2), w = addDays(t0, 7);
  let body;
  if (showDone) {
    const done = state.tasks.filter(t => t.isCompleted).sort((a, b) => new Date(b.completedAt || 0) - new Date(a.completedAt || 0));
    body = done.length ? done.map(taskRow).join('') : '<div class="muted">Nothing completed yet.</div>';
  } else {
    const open = state.tasks.filter(t => !t.isCompleted).sort((a, b) => (a.due ? new Date(a.due) : 8.64e15) - (b.due ? new Date(b.due) : 8.64e15));
    const groups = [['Overdue', t => t.due && new Date(t.due) < now], ['Today', t => t.due && new Date(t.due) >= now && new Date(t.due) < t1],
                    ['Tomorrow', t => t.due && new Date(t.due) >= t1 && new Date(t.due) < t2], ['This week', t => t.due && new Date(t.due) >= t2 && new Date(t.due) < w],
                    ['Later', t => t.due && new Date(t.due) >= w], ['No due date', t => !t.due]];
    body = groups.map(([name, f]) => {
      const list = open.filter(f);
      if (!list.length) return '';
      return `<div class="group ${name === 'Overdue' ? 'overdue' : ''}"><span>${name}</span><span>${durationText(list.reduce((s, t) => s + t.estimatedMinutes, 0))}</span></div>${list.map(taskRow).join('')}`;
    }).join('') || '<div class="muted">✅ All caught up!</div>';
  }
  const g = state.google;
  return `<div class="page"><div class="row" style="justify-content:space-between"><h1>Assignments</h1>
      <div class="seg"><button class="${showDone ? '' : 'on'}" id="upcoming">Upcoming</button><button class="${showDone ? 'on' : ''}" id="donebtn">Done</button></div></div>
    ${quickAdd()}
    <div class="card row" style="justify-content:space-between"><div class="row">🎓 <div>${g.school.signedIn ? `<b>Google Classroom</b><div class="small ${g.classroomError ? '' : 'muted'}" style="${g.classroomError ? 'color:#e5484d' : ''}">${esc(g.classroomError || (g.lastClassroom ? 'Synced ' + time(g.lastClassroom) : 'Not synced yet'))}</div>` : '<span class="muted">Connect Google Classroom in Settings to pull in assignments.</span>'}</div></div>
      ${g.school.signedIn ? '<button class="btn small" id="classroom">Sync</button>' : ''}</div>
    <div class="card">${body}</div></div>`;
}

// ---------------------------------------------------------------- Settings
function settings() {
  const s = state.settings, g = state.google, v = state.voice;
  const bed = `${String(Math.floor(s.bedtimeMinutes / 60)).padStart(2, '0')}:${String(s.bedtimeMinutes % 60).padStart(2, '0')}`;
  const acct = (role, label) => `<div class="row" style="justify-content:space-between"><div><b>${label}</b><div class="small muted">${g[role].signedIn ? esc(g[role].email || 'Signed in') : 'Not signed in'}</div></div>
    ${g[role].signedIn ? `<button class="btn small danger" data-signout="${role}">Sign out</button>` : `<button class="btn small primary" data-signin="${role}" ${state.prefs.googleClientId ? '' : 'disabled'}>Sign in with Google</button>`}</div>`;
  return `<div class="page"><h1>Settings</h1>
    <div class="card form"><h2>You</h2><label>Your name<input type="text" id="name" value="${esc(state.prefs.name)}"></label>
      <label class="row"><input type="checkbox" id="login" ${state.prefs.openAtLogin ? 'checked' : ''}> Start Blob when Windows starts</label>
      <div class="small muted">Press <b>Ctrl+Shift+B</b> anywhere (or click Blob in the corner) to talk. Blob doesn't listen in the background — the mic only turns on when you call it.</div></div>

    <div class="card form"><h2>Blob's voice & hearing</h2>
      ${v.installed ? `<div>✅ Installed — speech recognition and the Daniel voice run on this PC, offline.</div>`
        : `<div>Download Blob's offline voice and hearing (${v.sizeMB} MB, one time). Until then you can type to Blob, and it answers with Windows' built-in voice.</div>
           <div class="progress"><div id="vbar"></div></div><div class="small muted" id="vlabel"></div><button class="btn primary" id="vdl">Download</button>`}
      <label class="row"><input type="checkbox" id="speak" ${state.prefs.speak ? 'checked' : ''}> Speak replies out loud</label>
      <label>Voice<select id="sid">${[[24, 'Daniel — measured, newsreader'], [26, 'George — warm, refined'], [25, 'Fable — crisp, storyteller'], [27, 'Lewis — deeper, relaxed']].map(([id, n]) => `<option value="${id}" ${state.prefs.voiceSid === id ? 'selected' : ''}>${n}</option>`).join('')}</select></label></div>

    <div class="card form"><h2>Blob's brain</h2>
      <div>${state.claude ? '✅ Claude Code found — Blob asks Claude (your Pro plan, no extra cost) for anything beyond quick commands.' : '⚠️ Claude Code isn\'t installed on this PC. Quick commands still work. Install Claude Code from claude.com/claude-code and sign in with your Pro account for full answers.'}</div></div>

    <div class="card form"><h2>Google (sync with your Mac and iPhone)</h2>
      <label>OAuth client ID<input type="text" id="cid" value="${esc(state.prefs.googleClientId)}" placeholder="1234-abc.apps.googleusercontent.com"></label>
      <label>OAuth client secret<input type="password" id="csec" value="${esc(state.prefs.googleClientSecret)}" placeholder="GOCSPX-…"></label>
      <div class="small muted">In the same Google Cloud project your Mac uses: Credentials → Create credentials → OAuth client ID → type <b>Desktop app</b>. Paste its ID and secret here. (Using the same project means all your devices share one sync file.)</div>
      ${acct('school', 'School account (Classroom)')}
      ${g.school.signedIn ? '<button class="btn small" id="classroom2">Sync Classroom now</button>' : ''}
      ${acct('personal', 'Separate sync account (optional)')}
      <div class="row" style="justify-content:space-between"><div class="small ${g.syncError ? '' : 'muted'}" style="${g.syncError ? 'color:#e5484d' : ''}">${esc(g.syncError || (g.syncAccount ? `Syncing through ${g.syncAccount}` : 'Sync is off until you sign in.'))}</div>
        <button class="btn small" id="syncnow" ${g.syncAccount ? '' : 'disabled'}>Sync now</button></div></div>

    <div class="card form"><h2>Check-in planner</h2>
      <label>Done working by<input type="time" id="bed" value="${bed}"></label>
      <label>Focus blocks (minutes)<input type="number" id="focus" min="15" max="120" step="5" value="${s.focusBlockMinutes}"></label>
      <label>Breaks (minutes)<input type="number" id="brk" min="0" max="30" step="5" value="${s.breakMinutes}"></label>
      <label>Daily work goal (minutes)<input type="number" id="goal" min="30" max="480" step="15" value="${s.dailyWorkTargetMinutes}"></label></div></div>`;
}

// ---------------------------------------------------------------- events
function wire() {
  const qa = $('#qa');
  if (qa) {
    let t = null;
    qa.addEventListener('input', () => { clearTimeout(t); t = setTimeout(previewQuickAdd, 120); });
    qa.addEventListener('keydown', async e => {
      if (e.key !== 'Enter' || !qa.value.trim()) return;
      const msg = await blob.add(qa.value.trim(), qaKind);
      qa.value = ''; qaKind = null; toast(msg);
    });
  }
  const checkBlob = $('#checkblob'); if (checkBlob) BlobArt.animateBlob(checkBlob, { still: true });
  const on = (sel, ev, fn) => document.querySelectorAll(sel).forEach(el => el.addEventListener(ev, () => fn(el)));
  on('[data-toggle]', 'click', el => blob.toggleTask(el.dataset.toggle));
  on('[data-deltask]', 'click', el => confirm('Delete this to-do?') && blob.deleteTask(el.dataset.deltask));
  on('[data-delevent]', 'click', el => el.dataset.delevent && confirm('Delete this event (all repeats)?') && blob.deleteEvent(el.dataset.delevent));
  on('[data-start]', 'click', el => blob.startBlock(el.dataset.start));
  on('[data-done]', 'click', async el => { const m = await blob.completeBlock(el.dataset.done); if (m) toast(m); });
  on('[data-day]', 'click', el => { selected = new Date(+el.dataset.day); render(); });
  on('[data-signin]', 'click', async el => { try { await blob.googleSignIn(el.dataset.signin); toast('Signed in'); } catch (e) { toast(e.message); } });
  on('[data-signout]', 'click', el => blob.googleSignOut(el.dataset.signout));
  const click = (id, fn) => { const el = $(id); if (el) el.onclick = fn; };
  click('#checkin', async () => { await blob.checkIn(); toast('Your timeline is ready'); });
  click('#prevm', () => { month = new Date(month.getFullYear(), month.getMonth() - 1, 1); render(); });
  click('#nextm', () => { month = new Date(month.getFullYear(), month.getMonth() + 1, 1); render(); });
  click('#todaym', () => { month = new Date(new Date().getFullYear(), new Date().getMonth(), 1); selected = sod(new Date()); render(); });
  click('#upcoming', () => { showDone = false; render(); });
  click('#donebtn', () => { showDone = true; render(); });
  click('#classroom', async () => { const n = await blob.classroomNow(); toast(n ? `${n} new from Classroom` : 'Classroom is up to date'); });
  click('#classroom2', async () => { const n = await blob.classroomNow(); toast(n ? `${n} new from Classroom` : 'Classroom is up to date'); });
  click('#syncnow', async () => { await blob.syncNow(); toast('Synced'); });
  click('#vdl', async () => {
    $('#vdl').disabled = true;
    const off = blob.onVoiceProgress((f, label) => { const b = $('#vbar'); if (b) b.style.width = `${Math.round(f * 100)}%`; const l = $('#vlabel'); if (l) l.textContent = label; });
    try { await blob.voiceDownload(); toast("Blob's voice is ready"); } catch (e) { toast(e.message); }
    off();
  });
  const pref = (id, key, get) => { const el = $(id); if (el) el.onchange = () => blob.setPrefs({ [key]: get(el) }); };
  pref('#name', 'name', el => el.value.trim() || 'Arjun');
  pref('#login', 'openAtLogin', el => el.checked);
  pref('#speak', 'speak', el => el.checked);
  pref('#sid', 'voiceSid', el => +el.value);
  pref('#cid', 'googleClientId', el => el.value.trim());
  pref('#csec', 'googleClientSecret', el => el.value.trim());
  const setting = (id, key, get) => { const el = $(id); if (el) el.onchange = () => blob.updateSettings({ [key]: get(el) }); };
  setting('#bed', 'bedtimeMinutes', el => { const [h, m] = el.value.split(':').map(Number); return h * 60 + m; });
  setting('#focus', 'focusBlockMinutes', el => +el.value);
  setting('#brk', 'breakMinutes', el => +el.value);
  setting('#goal', 'dailyWorkTargetMinutes', el => +el.value);
}

refresh();
setInterval(() => { if (tab === 'today') render(); }, 60_000);
