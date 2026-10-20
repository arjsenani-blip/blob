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

let tab = 'today', state = null, selected = sod(new Date()), month = new Date(new Date().getFullYear(), new Date().getMonth(), 1), mode = 'upcoming', detailId = null;
const PACE_COLOR = { done: '#22c55e', ahead: '#14b8a6', onTrack: '#219ffa', behind: '#ff9e1a', atRisk: '#e5484d', overdue: '#e5484d', notStarted: '#8b8b96' };
const PACE_ICON = { done: '✓', ahead: '🐇', onTrack: '●', behind: '🐢', atRisk: '⚠', overdue: '⛔', notStarted: '○' };
const gradeColor = g => (g >= 90 ? '#22c55e' : g >= 80 ? '#219ffa' : g >= 70 ? '#ff9e1a' : '#e5484d');
const fmtNum = v => (Math.round(v) === v ? String(v) : v.toFixed(1));
BlobArt.animateBlob($('#miniblob'), { still: true });

document.querySelectorAll('nav button').forEach(b => b.addEventListener('click', () => go(b.dataset.tab)));
function go(t) { tab = t; document.querySelectorAll('nav button').forEach(b => b.classList.toggle('on', b.dataset.tab === t)); render(); }
blob.onState(() => refresh());
blob.onStage(t => {
  if (t === 'detail') { detailId = longTasks()[0]?.id || null; return go('tasks'); }
  detailId = null;
  if (t.startsWith('tasks:')) { mode = t.slice(6); return go('tasks'); }
  go(t);
});

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
  renderDetail();
  wire();
}

// ---------------------------------------------------------------- quick add (shared by Today and Calendar)
const quickAdd = () => `<div class="card"><div class="quick"><span class="spark">✨</span>
  <input id="qa" placeholder="Try “History project due nov 20 long-term” or “worked 45 min on the history essay”" autocomplete="off"></div>
  <div id="qaprev" class="preview chips"></div></div>`;
let qaKind = null;
async function previewQuickAdd() {
  const text = $('#qa').value.trim(), box = $('#qaprev');
  if (!text) { box.innerHTML = ''; qaKind = null; return; }
  const log = qaKind ? null : await blob.logPreview(text);
  if (log) {
    const i = log.intent;
    const what = { worked: () => chip('+' + durationText(i.minutes), '#a970f2', '⏱'), finishedStep: () => chip('Step done: ' + i.step, '#22c55e', '✓'),
      completed: () => chip('Mark done', '#22c55e', '✓'), started: () => chip('Started', '#219ffa', '▶'), progress: () => chip(i.percent + '% done', '#219ffa', '◔'),
      grade: () => chip(`${fmtNum(i.earned)}/${fmtNum(i.possible)}`, '#ff9e1a', '🏅'), planSteps: () => chip('Split into steps', '#785cff', '☰') }[i.kind]();
    box.innerHTML = `<span class="chip" style="--c:#14b8a6;cursor:pointer" id="kindchip" title="Add it as a to-do instead">📈 Log ⇄</span>` + what
      + (log.task ? chip(log.task.title, '#888') + (log.task.course ? chip(log.task.course, colorFor(log.task.course), '🎓') : '') : chip('Which assignment?', '#e5484d', '?'));
    $('#kindchip').onclick = () => { qaKind = 'task'; previewQuickAdd(); };
    return;
  }
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
    <div><h2>On the calendar</h2><div class="card">${agenda || '<div class="muted">☀️ Nothing scheduled today.</div>'}</div></div>
    ${longTermCard(3)}</div>`;
}

function longRow(t) {
  const c = PACE_COLOR[t._pace], pct = Math.round(t._progress * 100);
  const steps = (t.milestones || []).map(m => `<i style="background:${m.isDone ? c : 'var(--line)'}"></i>`).join('');
  const next = t._next ? `<div class="small" style="margin-top:4px">↳ Next: ${esc(t._next.title)}${t._next.due ? `<span style="color:${new Date(t._next.due) < new Date() ? '#e5484d' : 'var(--muted)'}"> · by ${dueText(t._next.due, false)}</span>` : ''}</div>` : '';
  return `<div class="long" data-open="${t.id}"><div class="row" style="justify-content:space-between"><b>${esc(t.title)}</b>${chip(t._paceLabel, c, PACE_ICON[t._pace])}</div>
    <div class="pbar" style="--c:${c}"><div style="width:${Math.max(2, pct)}%"></div>${t._expected > 0.02 && t._expected < 0.99 ? `<span style="left:${t._expected * 100}%"></span>` : ''}</div>
    <div class="chips">${t.course ? chip(t.course, colorFor(t.course)) : ''}${t.due ? chip('Due ' + dueText(t.due, false), '#ff9e1a', '⚑') : ''}<b class="small">${pct}%</b>${t._perDay ? `<span class="small muted">· ${durationText(t._perDay)}/day</span>` : ''}</div>
    ${next}${steps ? `<div class="stepsbar">${steps}</div>` : ''}</div>`;
}
const longTasks = () => state.tasks.filter(t => t._long && !t.isCompleted).sort((a, b) => (a.due ? new Date(a.due) : 8.64e15) - (b.due ? new Date(b.due) : 8.64e15));
function longTermCard(limit) {
  const items = longTasks().slice(0, limit);
  return items.length ? `<div><div class="row" style="justify-content:space-between"><h2>Long-term</h2><span class="muted small">${longTasks().length} in progress</span></div>
    <div class="card">${items.map(longRow).join('')}</div></div>` : '';
}

function agendaRow(o) {
  return `<div class="agenda-row"><div class="small" style="text-align:right">${o.isAllDay ? 'all day' : `<b>${time(o.start)}</b><br><span class="muted">${time(o.end)}</span>`}</div>
    <div class="bar" style="--c:${colorFor(o.tag || o.title)}"></div><div><b>${esc(o.title)}</b>${o.location ? `<div class="small muted">${esc(o.location)}</div>` : ''}</div>
    <button class="btn small danger" data-delevent="${o.eventID}" title="Delete event">✕</button></div>`;
}

function taskRow(t) {
  const overdue = !t.isCompleted && t.due && new Date(t.due) < new Date();
  const extra = t._long && !t.isCompleted ? chip(`${Math.round(t._progress * 100)}% · ${t._paceLabel}`, PACE_COLOR[t._pace], PACE_ICON[t._pace])
    : t._grade != null ? chip(Math.round(t._grade) + '%', gradeColor(t._grade), '🏅') : chip(durationText(t.estimatedMinutes), '#888', '⏱');
  return `<div class="tasks-row"><button class="check ${t.isCompleted ? 'on' : ''}" style="--c:${colorFor(t.course)}" data-toggle="${t.id}"></button>
    <div data-open="${t.id}" style="cursor:pointer"><div class="t" style="${t.isCompleted ? 'text-decoration:line-through;opacity:.6' : ''}">${esc(t.title)}</div>
      <div class="chips" style="margin-top:3px">${t.course ? chip(t.course, colorFor(t.course)) : ''}${t.due ? chip(dueText(t.due), overdue ? '#e5484d' : '#ff9e1a', overdue ? '⚠' : '⚑') : ''}${extra}</div></div>
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
  if (mode === 'done') {
    const done = state.tasks.filter(t => t.isCompleted).sort((a, b) => new Date(b.completedAt || 0) - new Date(a.completedAt || 0));
    body = `<div class="card">${done.length ? done.map(taskRow).join('') : '<div class="muted">Nothing completed yet.</div>'}</div>`;
  } else if (mode === 'long') {
    const items = longTasks();
    body = workloadChart() + `<div class="card"><div class="group"><span>In progress</span><span>${durationText(items.reduce((a, t) => a + t._remaining, 0))} left</span></div>
      ${items.map(longRow).join('') || '<div class="muted">No long-term assignments. Add one like “history project due nov 20 long-term” — it gets steps with dates automatically.</div>'}</div>`;
  } else if (mode === 'classes') {
    body = state.tracker.courses.map(c => `<div class="card"><div class="row" style="justify-content:space-between"><div class="row"><i class="dotc" style="--c:${colorFor(c.name)};margin:0"></i><h2 style="margin:0">${esc(c.name)}</h2></div>
        ${c.averageGrade != null ? `<b style="font-size:22px;color:${gradeColor(c.averageGrade)}">${Math.round(c.averageGrade)}%</b>` : ''}</div>
      <div class="chips" style="margin:8px 0">${chip(c.openCount + ' open', '#219ffa')}${c.overdueCount ? chip(c.overdueCount + ' overdue', '#e5484d', '⚠') : ''}${c.longTermCount ? chip(c.longTermCount + ' long-term', '#14b8a6', '📈') : ''}${chip(c.completedCount + ' done', '#22c55e', '✓')}</div>
      <div class="small muted">${[c.remainingMinutes ? `~${durationText(c.remainingMinutes)} of work left` : '', c.loggedMinutes ? `${durationText(c.loggedMinutes)} logged` : '', c.nextDue ? `next due ${dueText(c.nextDue, false)}` : '', c.gradedCount ? `${c.gradedCount} graded` : ''].filter(Boolean).join(' · ')}</div>
      <details style="margin-top:8px"><summary class="small">Assignments</summary>${state.tasks.filter(t => (t.course || 'Other') === c.name).sort((a, b) => (a.isCompleted - b.isCompleted) || ((a.due ? new Date(a.due) : 8.64e15) - (b.due ? new Date(b.due) : 8.64e15))).map(taskRow).join('')}</details></div>`).join('')
      || '<div class="card muted">Classes show up here once you have assignments.</div>';
  } else {
    const open = state.tasks.filter(t => !t.isCompleted).sort((a, b) => (a.due ? new Date(a.due) : 8.64e15) - (b.due ? new Date(b.due) : 8.64e15));
    const groups = [['Overdue', t => t.due && new Date(t.due) < now], ['Today', t => t.due && new Date(t.due) >= now && new Date(t.due) < t1],
                    ['Tomorrow', t => t.due && new Date(t.due) >= t1 && new Date(t.due) < t2], ['This week', t => t.due && new Date(t.due) >= t2 && new Date(t.due) < w],
                    ['Later', t => t.due && new Date(t.due) >= w], ['No due date', t => !t.due]];
    body = `<div class="card">${groups.map(([name, f]) => {
      const list = open.filter(f);
      if (!list.length) return '';
      return `<div class="group ${name === 'Overdue' ? 'overdue' : ''}"><span>${name}</span><span>${durationText(list.reduce((s, t) => s + t._remaining, 0))}</span></div>${list.map(taskRow).join('')}`;
    }).join('') || '<div class="muted">✅ All caught up!</div>'}</div>`;
  }
  const g = state.google;
  const seg = [['upcoming', 'Upcoming'], ['long', 'Long-term'], ['classes', 'Classes'], ['done', 'Done']].map(([k, n]) => `<button class="${mode === k ? 'on' : ''}" data-mode="${k}">${n}</button>`).join('');
  return `<div class="page"><div class="row" style="justify-content:space-between"><h1>Assignments</h1><div class="seg">${seg}</div></div>
    ${quickAdd()}
    <div class="card row" style="justify-content:space-between"><div class="row">🎓 <div>${g.school.signedIn ? `<b>Google Classroom</b><div class="small ${g.classroomError ? '' : 'muted'}" style="${g.classroomError ? 'color:#e5484d' : ''}">${esc(g.classroomError || (g.lastClassroom ? 'Synced ' + time(g.lastClassroom) : 'Not synced yet'))}</div>` : '<span class="muted">Connect Google Classroom in Settings to pull in assignments.</span>'}</div></div>
      ${g.school.signedIn ? '<button class="btn small" id="classroom">Sync</button>' : ''}</div>
    ${body}</div>`;
}

function workloadChart() {
  const days = state.tracker.workload, goal = state.settings.dailyWorkTargetMinutes;
  const max = Math.max(goal * 1.2, ...days.map(d => d.minutes), 60);
  const heavy = days.filter(d => d.minutes > goal).length;
  const bars = days.map(d => `<div class="wbar" title="${new Date(d.day).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' })}: ${durationText(d.minutes)}">
      <div style="height:${d.minutes / max * 100}%;background:${d.minutes > goal ? '#ff9e1a' : 'var(--grad)'}"></div>
      <span>${new Date(d.day).toLocaleDateString([], { weekday: 'narrow' })}${new Date(d.day).getDate()}</span></div>`).join('');
  return `<div class="card"><div class="row" style="justify-content:space-between"><h2 style="margin:0">Next 2 weeks</h2>
    <span class="small" style="font-weight:600;color:${heavy ? '#ff9e1a' : '#22c55e'}">${heavy ? `${heavy} heavy day${heavy === 1 ? '' : 's'} — start early` : 'Fits your daily goal'}</span></div>
    <div class="workload"><div class="goal" style="bottom:${goal / max * 100}%"></div>${bars}</div></div>`;
}

// ---------------------------------------------------------------- One assignment (detail)
function renderDetail() {
  let host = $('#detail');
  const t = detailId && state.tasks.find(x => x.id === detailId);
  if (!t) { if (host) host.remove(); detailId = null; return; }
  if (!host) { host = document.createElement('div'); host.id = 'detail'; document.body.appendChild(host); }
  const c = PACE_COLOR[t._pace], pct = Math.round(t._progress * 100);
  const steps = (t.milestones || []).map(m => {
    const late = !m.isDone && m.due && new Date(m.due) < new Date();
    const d = m.due ? new Date(m.due) : null, val = d ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : '';
    return `<div class="tasks-row"><button class="check ${m.isDone ? 'on' : ''}" style="--c:${late ? '#e5484d' : '#785cff'}" data-step="${m.id}"></button>
      <input class="stepname" data-stepname="${m.id}" value="${esc(m.title)}" style="${m.isDone ? 'text-decoration:line-through;opacity:.6' : ''}">
      <div class="row"><span class="small muted">${durationText(m.estimatedMinutes)}</span><input type="date" data-stepdue="${m.id}" value="${val}" style="${late ? 'color:#e5484d' : ''}"><button class="btn small danger" data-stepdel="${m.id}">✕</button></div></div>`;
  }).join('');
  const log = [...(t.sessions || [])].sort((a, b) => new Date(b.date) - new Date(a.date)).map(x => {
    const step = x.milestoneID && t.milestones.find(m => m.id === x.milestoneID);
    return `<div class="tasks-row" style="grid-template-columns:110px 1fr auto"><span class="small">${new Date(x.date).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' })}</span>
      <div>${x.minutes ? `<b>${durationText(x.minutes)}</b>` : ''}${step ? `<div class="small muted">${esc(step.title)}</div>` : ''}${x.note ? `<div class="small muted">${esc(x.note)}</div>` : ''}</div>
      <button class="btn small" data-sessdel="${x.id}">✕</button></div>`;
  }).join('');
  host.innerHTML = `<div class="sheet"><div class="row" style="justify-content:space-between"><span class="muted small">${esc(t.course || 'Assignment')}</span><button class="btn small" id="dclose">Close</button></div>
    <div class="card row" style="gap:16px"><div class="ring" style="--p:${pct};--c:${c}"><span>${pct}%</span></div>
      <div><h2 style="margin:0">${esc(t.title)}</h2><div class="chips" style="margin:6px 0">${chip(t._paceLabel, c, PACE_ICON[t._pace])}${t.due ? chip('Due ' + dueText(t.due), '#ff9e1a', '⚑') : ''}${t.isLate ? chip('Late', '#e5484d') : ''}</div>
      <div class="row small"><b>${durationText(t._logged)}</b> logged · ${t.isCompleted ? 'done' : `<b>~${durationText(t._remaining)}</b> left`}${t._perDay && !t.isCompleted ? ` · <b>${durationText(t._perDay)}</b>/day` : ''}
      ${t.link ? ` · <a href="#" id="dlink">Open in Classroom</a>` : ''}</div></div></div>
    <div class="card"><h2>Log work</h2><div class="row" style="flex-wrap:wrap">${[15, 30, 45, 60, 90].map(m => `<button class="btn small" data-addmin="${m}">+${durationText(m)}</button>`).join('')}
      ${t.isCompleted ? '' : '<button class="btn small primary" id="dmark" style="margin-left:auto">✓ Done</button>'}</div>
      <input id="dsay" style="width:100%;margin-top:10px;padding:8px 10px;border-radius:10px;border:1px solid var(--line);background:var(--bg)" placeholder="Or say it: “worked 40 min, wrote the intro” · “finished the outline” · “60% done”"></div>
    <div class="card"><div class="row" style="justify-content:space-between"><h2 style="margin:0">Steps</h2><button class="btn small" id="dplan">${t.milestones?.length ? 'Re-plan steps' : 'Suggest steps'}</button></div>
      ${steps || '<div class="muted small" style="margin-top:6px">Break it into steps with their own dates so it moves forward a bit at a time. The check-in planner then works on one step at a time.</div>'}
      <input id="dstep" style="width:100%;margin-top:8px;padding:8px 10px;border-radius:10px;border:1px solid var(--line);background:var(--bg)" placeholder="＋ Add a step"></div>
    <div class="card form"><div class="row" style="justify-content:space-between"><h2 style="margin:0">Grade</h2>${t._grade != null ? chip(Math.round(t._grade) + '%', gradeColor(t._grade), '🏅') : ''}</div>
      <div class="row"><input type="number" id="dearned" placeholder="Points" value="${t.pointsEarned ?? ''}" style="width:90px"> / <input type="number" id="dpossible" placeholder="Out of" value="${t.maxPoints ?? ''}" style="width:90px"><button class="btn small" id="dgrade">Save</button></div></div>
    <div class="card"><h2>Work log</h2>${log || '<div class="muted small">Nothing logged yet. Time from the check-in timeline lands here automatically.</div>'}</div></div>`;
  const id = t.id;
  host.onclick = e => { if (e.target === host) { detailId = null; renderDetail(); } };
  $('#dclose').onclick = () => { detailId = null; renderDetail(); };
  if ($('#dlink')) $('#dlink').onclick = e => { e.preventDefault(); window.open(t.link); };
  host.querySelectorAll('[data-addmin]').forEach(b => b.onclick = async () => toast(await blob.taskLog(id, +b.dataset.addmin)));
  if ($('#dmark')) $('#dmark').onclick = () => blob.markDone(id);
  $('#dsay').onkeydown = async e => { if (e.key === 'Enter' && e.target.value.trim()) { toast(await blob.taskSay(id, e.target.value.trim())); } };
  $('#dplan').onclick = () => blob.planSteps(id);
  $('#dstep').onkeydown = e => { if (e.key === 'Enter' && e.target.value.trim()) blob.stepAdd(id, e.target.value.trim()); };
  host.querySelectorAll('[data-step]').forEach(b => b.onclick = () => blob.stepToggle(id, b.dataset.step));
  host.querySelectorAll('[data-stepdel]').forEach(b => b.onclick = () => blob.stepDelete(id, b.dataset.stepdel));
  host.querySelectorAll('[data-stepname]').forEach(i => i.onchange = () => blob.stepUpdate(id, i.dataset.stepname, { title: i.value }));
  host.querySelectorAll('[data-stepdue]').forEach(i => i.onchange = () => { const [y, m, d] = i.value.split('-').map(Number); blob.stepUpdate(id, i.dataset.stepdue, { due: new Date(y, m - 1, d, 21) }); });
  host.querySelectorAll('[data-sessdel]').forEach(b => b.onclick = () => blob.deleteSession(id, b.dataset.sessdel));
  $('#dgrade').onclick = () => { const e = parseFloat($('#dearned').value); if (!isNaN(e)) { blob.setGrade(id, e, parseFloat($('#dpossible').value) || null); toast('Grade saved'); } };
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

    <div class="card form"><h2>Google Calendar</h2>
      ${state.calendar.account ? `<div>✅ Connected: ${esc(state.calendar.account)}</div>
        <label class="row"><input type="checkbox" id="gcalon" ${state.prefs.googleCalendarOn ? 'checked' : ''}> Show my Google Calendar events</label>
        <label class="row"><input type="checkbox" id="gcalpush" ${state.prefs.googleEventsPushOn ? 'checked' : ''}> Add Blob's events to Google Calendar</label>
        <label class="row"><input type="checkbox" id="gtasks" ${state.prefs.googleTasksOn ? 'checked' : ''}> Assignments show up as tasks in Google Calendar (Google Tasks)</label>
        <button class="btn small" id="gcalnow">${state.calendar.busy ? '⟳ Syncing…' : 'Sync Google Calendar now'}</button>`
      : `<div class="muted small">${g.school.signedIn || g.personal.signedIn ? 'Connect the account whose calendar you use.' : 'Sign in with Google above first.'}</div>`}
      ${state.calendar.connectable.map(a => `<button class="btn small primary" data-gcal="${a.role}">Connect Google Calendar on ${esc(a.email || a.role)}</button>`).join('')}
      ${state.calendar.error ? `<div class="small" style="color:#e5484d">${esc(state.calendar.error)}</div>` : ''}
      <div class="small muted">Needs the <b>Google Calendar API</b> and <b>Google Tasks API</b> turned on in your Google Cloud project. Ticking off a task in Google Calendar marks it done in Blob. (Apple Calendar sync is on the Mac and iPhone apps.)</div></div>

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
      const msg = await blob.add(qa.value.trim(), qaKind === 'task' && (await blob.logPreview(qa.value.trim())) ? 'task' : qaKind);
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
  on('[data-mode]', 'click', el => { mode = el.dataset.mode; render(); });
  on('[data-open]', 'click', el => { detailId = el.dataset.open; renderDetail(); });
  on('[data-gcal]', 'click', async el => { try { await blob.connectCalendar(el.dataset.gcal); toast('Google Calendar connected'); } catch (e) { toast(e.message); } });
  click('#gcalnow', () => blob.calendarNow());
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
  pref('#gcalon', 'googleCalendarOn', el => el.checked);
  pref('#gcalpush', 'googleEventsPushOn', el => el.checked);
  pref('#gtasks', 'googleTasksOn', el => el.checked);
  const setting = (id, key, get) => { const el = $(id); if (el) el.onchange = () => blob.updateSettings({ [key]: get(el) }); };
  setting('#bed', 'bedtimeMinutes', el => { const [h, m] = el.value.split(':').map(Number); return h * 60 + m; });
  setting('#focus', 'focusBlockMinutes', el => +el.value);
  setting('#brk', 'breakMinutes', el => +el.value);
  setting('#goal', 'dailyWorkTargetMinutes', el => +el.value);
}

refresh();
setInterval(() => { if (tab === 'today') render(); }, 60_000);
