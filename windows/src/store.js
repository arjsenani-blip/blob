// Blob's planner data on Windows: the same document the Mac and iPhone apps sync, saved in %APPDATA%\Blob.
'use strict';
const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');
const { emptyDoc, decodeDoc, encodeDoc, occurrences, task: newTask, event: newEvent } = require('./core/model');
const { Parser } = require('./core/parser');
const { Scheduler } = require('./core/scheduler');
const { merge } = require('./core/merge');
const { startOfDay, addDays, sameDay } = require('./core/dates');

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
      this.upsertTask(newTask({ title, course: p.course || p.tag || null, due: p.start, estimatedMinutes: p.durationMinutes || 30,
                                priority: p.priority, estimateIsUserSet: p.durationMinutes != null }));
      return `Added to-do: ${title}`;
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
    const t = this.task(id); if (!t) return;
    this.upsertTask({ ...t, isCompleted: !t.isCompleted, completedAt: t.isCompleted ? null : new Date() });
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
    const t = b.taskID && this.task(b.taskID);
    if (!t) return null;
    const spent = b.startedAt ? Math.max(1, Math.round((Date.now() - b.startedAt) / 60000)) : Math.round((b.end - b.start) / 60000);
    const final = b.part == null || b.part === b.partsTotal;
    this.upsertTask({ ...t, actualMinutes: (t.actualMinutes || 0) + spent, ...(final ? { isCompleted: true, completedAt: new Date() } : {}) });
    return final ? `Nice — ${t.title} done ✓` : null;
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
