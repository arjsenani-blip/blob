// Blob's planner data on Windows: the same document the Mac and iPhone apps sync, saved in %APPDATA%\Blob.
'use strict';
const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');
const { emptyDoc, decodeDoc, encodeDoc, occurrences, newId, task: newTask, event: newEvent } = require('./core/model');
const { Parser } = require('./core/parser');
const { Scheduler } = require('./core/scheduler');
const { merge } = require('./core/merge');
const { startOfDay, addDays, sameDay, dueText } = require('./core/dates');
const tracking = require('./core/tracking');
const { parseLog, bestTask, bestStep, overlap, words } = require('./core/progresslog');
const { durationText } = require('./core/scheduler');

const fmt = v => (Math.round(v) === v ? String(v) : v.toFixed(1));

class Store extends EventEmitter {
  constructor(dir) {
    super();
    this.file = path.join(dir, 'brain.json');
    fs.mkdirSync(dir, { recursive: true });
    try { this.doc = decodeDoc(fs.readFileSync(this.file, 'utf8')); } catch { this.doc = emptyDoc(); }
  }

  save() {
    const tmp = this.file + '.tmp';
    fs.writeFileSync(tmp, encodeDoc(this.doc));
    fs.renameSync(tmp, this.file);
  }

  changed() {
    this.save();
    this.emit('changed');
  }

  // ---- Reads ----
  get events() { return this.doc.events.filter(e => !e.deleted); }
  get tasks() { return this.doc.tasks.filter(t => !t.deleted); }
  get pending() { return this.tasks.filter(t => !t.isCompleted); }
  get knownCourses() { return [...new Set(this.tasks.map(t => t.course).filter(Boolean))].sort(); }
  task(id) { return this.doc.tasks.find(t => t.id === id); }
  event(id) { return this.doc.events.find(e => e.id === id); }

  occurrencesIn(start, end) {
    return this.events.flatMap(e => occurrences(e, start, end))
      .sort((a, b) => (a.isAllDay === b.isAllDay ? a.start - b.start : a.isAllDay ? -1 : 1));
  }
  occurrencesOn(day) { const s = startOfDay(day); return this.occurrencesIn(s, addDays(s, 1)); }
  dueOn(day) { return this.tasks.filter(t => t.due && sameDay(t.due, day)).sort((a, b) => a.due - b.due); }

  get todayPlan() {
    return this.doc.plans.filter(p => !p.deleted && sameDay(p.checkInAt, new Date())).sort((a, b) => b.checkInAt - a.checkInAt)[0] || null;
  }

  // ---- Quick add ----
  parse(text) { return new Parser({ courses: this.knownCourses }).parse(text); }

  add(p, kind = p.kind) {
    const title = p.title || 'Untitled';
    if (kind === 'task') {
      // "long-term" / "big project" in the text means: track it over days with steps.
      const longRe = /\s*\b(long[- ]?term|big project|track (it|this))\b\s*/i;
      const explicit = longRe.test(title);
      const clean = explicit ? title.replace(longRe, ' ').trim() || title : title;
      const t = newTask({ title: clean, course: p.course || p.tag || null, due: p.start, estimatedMinutes: p.durationMinutes || 30,
                          priority: p.priority, estimateIsUserSet: p.durationMinutes != null });
      this.upsertTask(t);
      const steps = this.setUpLongTerm(t.id, explicit);
      return steps ? `Tracking ${clean} long-term · ${steps} steps` : `Added to-do: ${clean}`;
    }
    const start = p.start || (() => { const d = new Date(); d.setHours(d.getHours() + 1, 0, 0, 0); return d; })();
    this.upsertEvent(newEvent({ title, start, end: p.end || new Date(start.getTime() + 3600e3), isAllDay: p.isAllDay,
                                location: p.location || null, tag: p.tag || null, recurrence: p.recurrence }));
    return `Added: ${title}`;
  }

  // ---- Mutations (every change stamps updatedAt so sync knows which edit is newest) ----
  upsertTask(t) {
    t = { ...t, updatedAt: new Date() };
    const i = this.doc.tasks.findIndex(x => x.id === t.id);
    if (i >= 0) this.doc.tasks[i] = t; else this.doc.tasks.push(t);
    this.changed();
  }
  upsertEvent(e) {
    e = { ...e, updatedAt: new Date() };
    const i = this.doc.events.findIndex(x => x.id === e.id);
    if (i >= 0) this.doc.events[i] = e; else this.doc.events.push(e);
    this.changed();
  }
  toggleTask(id) {
    const t0 = this.task(id); if (!t0) return;
    const t = this.copy(t0);
    if (t.isCompleted) { t.isCompleted = false; t.completedAt = null; } else this.markDone(t);
    this.upsertTask(t);
  }
  deleteTask(id) { const t = this.task(id); if (t) this.upsertTask({ ...t, deleted: true }); }
  deleteEvent(id) { const e = this.event(id); if (e) this.upsertEvent({ ...e, deleted: true }); }
  updateSettings(patch) {
    this.doc.settings = { ...this.doc.settings, ...patch, updatedAt: new Date() };
    this.changed();
  }

  checkIn() {
    const progress = {};
    for (const b of this.todayPlan?.blocks || []) if (b.kind === 'task' && b.isDone && b.taskID) progress[b.taskID] = (progress[b.taskID] || 0) + (b.end - b.start) / 60000;
    const now = new Date();
    const plan = new Scheduler(this.doc.settings).makePlan(now, this.tasks, this.occurrencesIn(now, new Date(now.getTime() + 30 * 3600e3)), progress);
    this.doc.plans.push(plan);
    this.changed();
    return plan;
  }

  updateBlock(blockId, patch) {
    const plan = this.todayPlan; if (!plan) return;
    const b = plan.blocks.find(x => x.id === blockId); if (!b) return;
    Object.assign(b, patch);
    plan.updatedAt = new Date();
    this.changed();
  }

  completeBlock(blockId) {
    const b = this.todayPlan?.blocks.find(x => x.id === blockId); if (!b) return null;
    this.updateBlock(blockId, { isDone: true });
    const t0 = b.taskID && this.task(b.taskID);
    if (!t0) return null;
    const t = this.copy(t0);
    const spent = b.startedAt ? Math.max(1, Math.round((Date.now() - b.startedAt) / 60000)) : Math.round((b.end - b.start) / 60000);
    this.logWork(t, spent, null, b.milestoneID || null);
    const final = b.part == null || b.part === b.partsTotal;
    let msg = null;
    if (final && !b.sessionOnly) {
      if (b.milestoneID) {
        this.finishStep(t, b.milestoneID);
        const next = tracking.nextMilestone(t);
        msg = t.isCompleted ? `Nice — ${t.title} done ✓` : 'Step done ✓' + (next ? ` Next: ${next.title}` : '');
      } else { this.markDone(t); msg = `Nice — ${t.title} done ✓`; }
    } else if (final) msg = `Logged ${durationText(spent)} · ${Math.round(tracking.progress(t) * 100)}% done`;
    this.upsertTask(t);
    return msg;
  }

  // ---- Long-term tracking ----

  copy(t) { return { ...t, milestones: (t.milestones || []).map(m => ({ ...m })), sessions: [...(t.sessions || [])] }; }

  get currentBlockTaskId() {
    const now = new Date();
    return this.todayPlan?.blocks.find(b => b.kind === 'task' && !b.isDone && (b.startedAt || (b.start <= now && now <= b.end)))?.taskID || null;
  }

  logPreview(text) {
    const intent = parseLog(text);
    if (!intent) return null;
    const t = bestTask(intent.query, this.tasks, this.currentBlockTaskId);
    return { intent, task: t ? { id: t.id, title: t.title, course: t.course || null } : null };
  }

  /** Applies a log sentence; returns what happened (for a toast or for Blob to say), or null if it isn't one. */
  applyLog(text) {
    const intent = parseLog(text);
    return intent ? this.applyIntent(intent) : null;
  }

  applyIntent(intent, taskId = null) {
    const found = taskId ? this.task(taskId) : bestTask(intent.query, this.tasks, this.currentBlockTaskId);
    if (!found) return "I couldn't tell which assignment you meant. Try including its name or class.";
    const t = this.copy(found);
    let msg;
    const status = () => (!t.isCompleted && t.due ? ` — ${Math.round(tracking.progress(t) * 100)}% done, ${tracking.PACE_LABEL[tracking.pace(t)].toLowerCase()}` : '');
    switch (intent.kind) {
      case 'worked':
        this.logWork(t, intent.minutes, intent.note, tracking.nextMilestone(t)?.id || null);
        msg = `Logged ${durationText(intent.minutes)} on ${t.title}` + status(); break;
      case 'finishedStep': {
        const m = bestStep(intent.step, t);
        if (m) {
          this.finishStep(t, m.id);
          const next = tracking.nextMilestone(t);
          msg = t.isCompleted ? `${t.title} is all done ✓` : `Checked off “${m.title}” for ${t.title}` + (next ? `. Next: ${next.title}` : '') + status();
        } else { this.logWork(t, 0, `Finished ${intent.step}`, null); msg = `Noted: finished ${intent.step} for ${t.title}`; }
        break;
      }
      case 'completed':
        if (taskId && t.milestones.length) {
          const m = bestStep(intent.query, t);
          if (m && overlap(words(intent.query), m.title) > 0) { this.finishStep(t, m.id); msg = `Checked off “${m.title}”`; break; }
        }
        this.markDone(t); msg = `${t.title} — done ✓`; break;
      case 'started':
        if (!t.startDate || t.startDate > new Date()) t.startDate = new Date();
        msg = `Started ${t.title}` + (tracking.nextMilestone(t) ? `. First step: ${tracking.nextMilestone(t).title}` : ''); break;
      case 'progress':
        this.setProgress(t, intent.percent);
        msg = `${t.title} is ${Math.round(tracking.progress(t) * 100)}% done` + status(); break;
      case 'grade':
        t.pointsEarned = intent.earned; t.maxPoints = intent.possible;
        if (!t.isCompleted) this.markDone(t);
        msg = `Saved ${fmt(intent.earned)}/${fmt(intent.possible)} (${Math.round(intent.earned / intent.possible * 100)}%) for ${t.title}`; break;
      case 'planSteps':
        this.planSteps(t);
        msg = `Split ${t.title} into ${t.milestones.length} steps: ` + t.milestones.map(m => m.title).join(', '); break;
      default: msg = 'Noted.';
    }
    this.upsertTask(t);
    return msg;
  }

  logWork(t, minutes, note, milestoneID, date = new Date()) {
    if (!t.sessions.length && t.actualMinutes > 0) t.sessions.push({ id: newId(), date: t.completedAt || date, minutes: t.actualMinutes, note: 'Earlier work' });
    if (minutes > 0 || note) t.sessions.push({ id: newId(), date, minutes, note: note || null, milestoneID: milestoneID || null });
    t.actualMinutes = t.sessions.reduce((a, s) => a + s.minutes, 0);
    if (!t.startDate) t.startDate = date;
  }

  finishStep(t, id) {
    const m = t.milestones.find(x => x.id === id); if (!m) return;
    m.isDone = true; m.doneAt = new Date();
    if (!t.startDate) t.startDate = new Date();
    if (t.milestones.every(x => x.isDone)) this.markDone(t);
  }

  markDone(t) {
    t.isCompleted = true; t.completedAt = new Date();
    for (const m of t.milestones) if (!m.isDone) { m.isDone = true; m.doneAt = new Date(); }
  }

  setProgress(t, percent) {
    if (percent >= 100) { this.markDone(t); return; }
    if (t.milestones.length) {
      const total = tracking.totalEstimate(t);
      let acc = 0;
      for (const m of t.milestones) { acc += m.estimatedMinutes; if (acc / total <= percent / 100 + 0.02 && !m.isDone) { m.isDone = true; m.doneAt = new Date(); } }
    } else {
      const missing = Math.round(t.estimatedMinutes * percent / 100) - tracking.loggedMinutes(t);
      if (missing > 0) this.logWork(t, missing, `Marked ${percent}% done`, null);
    }
    if (!t.startDate) t.startDate = new Date();
  }

  planSteps(t) {
    const now = new Date();
    if (!t.due) t.due = addDays(now, 14);
    let total = t.estimateIsUserSet ? t.estimatedMinutes : Math.max(t.estimatedMinutes, tracking.defaultEstimate(t.title) || 180);
    total = Math.max(total - tracking.loggedMinutes(t), 30);
    const start = new Date(Math.max(now, t.startDate || now));
    t.milestones = [...t.milestones.filter(m => m.isDone), ...tracking.suggestSteps(t.title, start, t.due, total)];
    if (!t.startDate) t.startDate = t.createdAt || now;
  }

  /** Big assignments far enough out get steps automatically. Returns the number of steps, or 0. */
  setUpLongTerm(id, explicit = false) {
    const t0 = this.task(id);
    if (!t0 || t0.milestones?.length || !tracking.looksLongTerm(t0.title, t0.due, new Date(), explicit)) return 0;
    const t = this.copy(t0);
    if (!t.estimateIsUserSet && tracking.defaultEstimate(t.title)) t.estimatedMinutes = tracking.defaultEstimate(t.title);
    t.startDate = new Date();
    this.planSteps(t);
    this.upsertTask(t);
    return t.milestones.length;
  }

  trackerSummary(now = new Date()) {
    const long = this.pending.filter(tracking.isLongTerm).sort((a, b) => (a.due || Infinity) - (b.due || Infinity));
    if (!long.length) return "You don't have any long-term assignments right now.";
    return long.slice(0, 6).map(t => {
      let s = `${t.title}: ${Math.round(tracking.progress(t) * 100)}% done, ${tracking.PACE_LABEL[tracking.pace(t, now)].toLowerCase()}`;
      if (t.due) s += `, due ${dueText(t.due, false)}`;
      const m = tracking.nextMilestone(t);
      if (m) s += `. Next step: ${m.title}` + (m.due ? ` by ${dueText(m.due, false)}` : '');
      const need = tracking.minutesPerDayNeeded(t, now);
      if (need) s += ` (about ${durationText(need)} a day)`;
      return s;
    }).join('\n');
  }

  /** Merge in another device's copy (from Drive). */
  mergeRemote(remote) {
    const merged = merge(this.doc, remote);
    const before = encodeDoc(this.doc);
    this.doc = merged;
    if (encodeDoc(merged) !== before) this.changed();
    return merged;
  }
}

module.exports = { Store };
