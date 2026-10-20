// Data model shared with the Mac/iPhone apps (BrainCore/Models.swift). Converts to/from the exact JSON the
// Swift apps write, so the same synced file works on all three.
'use strict';
const crypto = require('crypto');
const { startOfDay, addDays, at, weekdayOf, toSwift, fromSwift } = require('./dates');

const newId = () => crypto.randomUUID().toUpperCase();

/** Same as Swift's UUID.stable(from:) — so a Classroom assignment gets the same id on every device. */
function stableId(key) {
  const b = crypto.createHash('sha1').update(key, 'utf8').digest().subarray(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex').toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

const defaultSettings = () => ({ bedtimeMinutes: 22 * 60 + 30, focusBlockMinutes: 45, breakMinutes: 10, dailyWorkTargetMinutes: 180, lateSessionMinutes: 60, updatedAt: new Date(REF_PAST) });
const REF_PAST = -62135769600000;           // Swift's .distantPast
const emptyDoc = () => ({ schemaVersion: 1, events: [], tasks: [], plans: [], settings: defaultSettings() });

function event(fields) {
  return { id: newId(), isAllDay: false, recurrence: { frequency: 'none', weekdays: [] }, excludedDays: [], updatedAt: new Date(), deleted: false, ...fields };
}
function task(fields) {
  return { id: newId(), estimatedMinutes: 30, difficulty: 2, priority: 1, source: 'manual', isCompleted: false, estimateIsUserSet: false, updatedAt: new Date(), deleted: false, due: null, ...fields };
}

// ---- JSON (Swift Codable) <-> JS ----

const DATE_FIELDS = {
  event: ['start', 'end', 'updatedAt'], task: ['due', 'completedAt', 'updatedAt'],
  block: ['start', 'end', 'startedAt'], plan: ['checkInAt', 'windowEnd', 'updatedAt'], settings: ['updatedAt'],
};
// JS dates hold milliseconds; the Swift apps store microseconds. Keep the exact original value for any date
// that hasn't changed, so the Windows app never rewrites synced data it didn't touch.
const precise = new WeakMap();
function dec(o, kind) {
  const r = { ...o };
  const exact = {};
  for (const f of DATE_FIELDS[kind]) {
    r[f] = o[f] == null ? null : fromSwift(o[f]);
    if (o[f] != null) exact[f] = o[f];
  }
  precise.set(r, exact);
  return r;
}
function enc(o, kind) {
  const r = {};
  const exact = precise.get(o) || {};
  for (const [k, v] of Object.entries(o)) {
    if (v === null || v === undefined) continue;          // Swift omits nil optionals
    if (DATE_FIELDS[kind].includes(k)) {
      const s = toSwift(v);
      r[k] = exact[k] !== undefined && Math.abs(exact[k] - s) < 0.001 ? exact[k] : s;
    } else r[k] = v;
  }
  return r;
}

function decodeDoc(json) {
  const d = typeof json === 'string' ? JSON.parse(json) : json;
  return {
    schemaVersion: d.schemaVersion ?? 1,
    events: (d.events || []).map(e => {
      const r = dec(e, 'event');
      r.excludedDays = (e.excludedDays || []).map(fromSwift);
      r.recurrence = { frequency: 'none', weekdays: [], ...(e.recurrence || {}) };
      if (r.recurrence.until != null) r.recurrence.until = fromSwift(r.recurrence.until);
      return r;
    }),
    tasks: (d.tasks || []).map(t => dec(t, 'task')),
    plans: (d.plans || []).map(p => { const r = dec(p, 'plan'); r.blocks = (p.blocks || []).map(b => dec(b, 'block')); return r; }),
    settings: d.settings ? dec(d.settings, 'settings') : defaultSettings(),
  };
}

function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, sortKeys(v[k])]));
  return v;
}

function encodeDoc(doc) {
  const out = {
    schemaVersion: doc.schemaVersion ?? 1,
    events: doc.events.map(e => {
      const r = enc(e, 'event');
      r.excludedDays = (e.excludedDays || []).map(toSwift);
      const rec = { frequency: e.recurrence?.frequency || 'none', weekdays: e.recurrence?.weekdays || [] };
      if (e.recurrence?.until) rec.until = toSwift(e.recurrence.until);
      r.recurrence = rec;
      return r;
    }),
    tasks: doc.tasks.map(t => enc(t, 'task')),
    plans: doc.plans.map(p => { const r = enc(p, 'plan'); r.blocks = p.blocks.map(b => enc(b, 'block')); return r; }),
    settings: enc(doc.settings, 'settings'),
  };
  return JSON.stringify(sortKeys(out));                  // sorted keys, like the Swift encoder
}

// ---- Calendar occurrences (repeating events) ----

function occurrences(ev, rangeStart, rangeEnd) {
  if (ev.deleted) return [];
  const duration = Math.max(0, ev.end - ev.start);
  const make = s => {
    const st = ev.isAllDay ? startOfDay(s) : s;
    const spanDays = Math.max(1, Math.round((startOfDay(ev.end) - startOfDay(ev.start)) / 86400000));
    const en = ev.isAllDay ? addDays(st, spanDays) : new Date(st.getTime() + duration);
    return { id: `${ev.id}@${Math.floor(st.getTime() / 1000)}`, eventID: ev.id, title: ev.title, start: st, end: en,
             isAllDay: ev.isAllDay, location: ev.location || null, tag: ev.tag || null };
  };
  const overlaps = o => (o.end > rangeStart && o.start < rangeEnd) || (o.start.getTime() === o.end.getTime() && o.start >= rangeStart && o.start < rangeEnd);
  const rec = ev.recurrence || { frequency: 'none' };
  if (rec.frequency === 'none') { const o = make(ev.start); return overlaps(o) ? [o] : []; }

  const startDay = startOfDay(ev.start);
  let day = startOfDay(new Date(Math.max(ev.start, rangeStart - Math.max(duration, 86400000))));
  if (day < startDay) day = startDay;
  const limit = rec.until ? Math.min(rangeEnd, addDays(startOfDay(rec.until), 1)) : rangeEnd;
  const excluded = new Set((ev.excludedDays || []).map(d => startOfDay(d).getTime()));
  const startWd = weekdayOf(ev.start), startDom = ev.start.getDate();
  const out = [];
  for (let n = 0; day < limit && n < 3000; n++, day = addDays(day, 1)) {
    const wd = weekdayOf(day);
    const ok = rec.frequency === 'daily' ? true
      : rec.frequency === 'weekdays' ? wd >= 2 && wd <= 6
      : rec.frequency === 'weekly' ? (rec.weekdays?.length ? rec.weekdays.includes(wd) : wd === startWd)
      : rec.frequency === 'monthly' ? day.getDate() === startDom : false;
    if (ok && !excluded.has(day.getTime())) {
      const o = make(at(day, [ev.start.getHours(), ev.start.getMinutes()]));
      if (overlaps(o)) out.push(o);
    }
  }
  return out;
}

module.exports = { newId, stableId, event, task, emptyDoc, defaultSettings, decodeDoc, encodeDoc, occurrences };
