// Check-in planner — port of BrainCore/Scheduler.swift. Same rules: urgency tiers, energy by time of day,
// a quick warm-up, earliest-deadline fallback when the smart order would make something late, focus blocks + breaks.
'use strict';
const { startOfDay, addDays, shortTime } = require('./dates');
const { newId } = require('./model');

const TIER = { overdue: 0, beforeMorning: 1, tomorrow: 2, thisWeek: 3, later: 4, someday: 5 };
const MIN = 60000;

function durationText(m) {
  const h = Math.floor(m / 60), r = m % 60;
  if (h === 0) return `${r}m`;
  return r === 0 ? `${h}h` : `${h}h ${r}m`;
}

class Scheduler {
  constructor(settings) { this.s = settings; }

  roundUp(d) {
    const base = new Date(d); base.setSeconds(0, 0);
    let r = new Date(base.getTime() + ((5 - (base.getMinutes() % 5)) % 5) * MIN);
    if (r < d) r = new Date(r.getTime() + 5 * MIN);
    return r;
  }

  workWindow(start) {
    const bedtime = new Date(startOfDay(start).getTime() + this.s.bedtimeMinutes * MIN);
    const late = new Date(start.getTime() + this.s.lateSessionMinutes * MIN);
    if (start.getHours() < 4 || start >= new Date(bedtime.getTime() - 20 * MIN)) return [late, true];
    return [bedtime, false];
  }

  freeSlots(start, end, busy) {
    const slots = []; let cursor = start;
    for (const b of [...busy].sort((a, c) => a.start - c.start)) {
      if (b.start > cursor) slots.push({ start: cursor, end: new Date(Math.min(b.start, end)) });
      cursor = new Date(Math.max(cursor, b.end));
      if (cursor >= end) break;
    }
    if (cursor < end) slots.push({ start: cursor, end });
    return slots.filter(s => s.end - s.start >= 5 * MIN);
  }

  tier(due, start) {
    if (!due) return TIER.someday;
    const sod = startOfDay(start);
    const morningBase = start.getHours() < 4 ? sod : addDays(sod, 1);
    const nextMorning = new Date(morningBase.getTime() + 8 * 3600e3);
    const tomorrowEnd = addDays(startOfDay(nextMorning), 1);
    if (due < start) return TIER.overdue;
    if (due <= nextMorning) return TIER.beforeMorning;
    if (due <= tomorrowEnd) return TIER.tomorrow;
    if (due <= new Date(start.getTime() + 7 * 86400e3)) return TIER.thisWeek;
    return TIER.later;
  }

  energy(d) {
    const h = d.getHours();
    if (h >= 5 && h < 8) return 0.6;
    if (h >= 8 && h < 12) return 0.8;
    if (h >= 12 && h < 14) return 0.65;
    if (h >= 14 && h < 15) return 0.55;
    if (h >= 15 && h < 18) return 0.85;
    if (h >= 18 && h < 20) return 0.75;
    if (h >= 20 && h < 22) return 0.55;
    return 0.35;
  }

  edf(a, b) {
    const da = a.task.due ? a.task.due.getTime() : Infinity, db = b.task.due ? b.task.due.getTime() : Infinity;
    if (da !== db) return da - db;
    if (a.task.priority !== b.task.priority) return b.task.priority - a.task.priority;
    return a.minutes - b.minutes;
  }

  smartOrder(items, energy) {
    const high = energy >= 0.7;
    const ordered = [...items].sort((a, b) => {
      if (a.tier !== b.tier) return a.tier - b.tier;
      if (high) {
        if (a.task.difficulty !== b.task.difficulty) return b.task.difficulty - a.task.difficulty;
        if (a.task.priority !== b.task.priority) return b.task.priority - a.task.priority;
      } else {
        if (a.task.priority !== b.task.priority) return b.task.priority - a.task.priority;
        if (a.minutes !== b.minutes) return a.minutes - b.minutes;
      }
      return this.edf(a, b);
    });
    if (ordered.length && ordered[0].minutes > 20) {
      const i = ordered.findIndex(x => x.tier <= TIER.tomorrow && x.minutes <= 20 && x.task.difficulty <= 2);
      if (i >= 0) { const [w] = ordered.splice(i, 1); ordered.unshift({ ...w, warm: true }); }
    }
    return ordered;
  }

  simulate(order, slots, start, energy) {
    const sim = { blocks: [], overflow: [], late: 0, work: 0, finish: null };
    let si = 0, cursor = slots[0] ? slots[0].start : start, continuous = 0;
    const focus = Math.max(15, this.s.focusBlockMinutes);
    for (const item of order) {
      const urgent = item.tier <= TIER.tomorrow;
      if (!urgent && sim.work >= this.s.dailyWorkTargetMinutes) continue;
      if (si >= slots.length) {
        if (urgent) sim.overflow.push(item.task.id);
        if (item.tier <= TIER.beforeMorning) sim.late += 600;
        continue;
      }
      let remaining = item.minutes;
      const parts = [];
      let pendingBreak = continuous >= 25 && remaining <= focus && continuous + remaining > focus + 10;
      const blockLimit = continuous > 0 && continuous < 25 && continuous + remaining <= focus + 20 ? continuous + remaining : focus;
      while (remaining > 0 && si < slots.length) {
        const slot = slots[si];
        if (cursor < slot.start) { cursor = slot.start; continuous = 0; }
        const available = Math.floor((slot.end - cursor) / MIN);
        if (available < 5) { si++; continuous = 0; continue; }
        if (continuous >= blockLimit || pendingBreak) {
          const len = Math.min(this.s.breakMinutes, available);
          if (available - len < 10) { si++; continuous = 0; pendingBreak = false; continue; }
          const end = new Date(cursor.getTime() + len * MIN);
          sim.blocks.push({ id: newId(), kind: 'breakTime', title: 'Break', start: cursor, end, reason: 'Stand up, drink water, look away from the screen', isDone: false });
          cursor = end; continuous = 0; pendingBreak = false;
          continue;
        }
        let chunk = Math.min(remaining, Math.max(5, blockLimit - continuous), available);
        if (remaining - chunk <= 10 && remaining <= available) chunk = remaining;
        const end = new Date(cursor.getTime() + chunk * MIN);
        parts.push({ start: cursor, end });
        cursor = end; continuous += chunk; remaining -= chunk; sim.work += chunk;
        if (remaining > 0 && continuous >= blockLimit) pendingBreak = true;
      }
      if (remaining > 0 && urgent) sim.overflow.push(item.task.id);
      if (parts.length) {
        const reason = this.reason(item, energy, start);
        const total = parts.length + (remaining > 0 ? 1 : 0);
        parts.forEach((p, i) => sim.blocks.push({
          id: newId(), kind: 'task', title: item.task.title, subtitle: item.task.course || null, start: p.start, end: p.end,
          reason: i === 0 ? reason : 'Keep going', taskID: item.task.id, part: total > 1 ? i + 1 : null, partsTotal: total > 1 ? total : null, isDone: false,
        }));
        sim.finish = parts[parts.length - 1].end;
      }
      const due = item.task.due;
      if (due && (due > start || item.tier === TIER.overdue)) {
        const finish = remaining > 0 ? new Date((slots.length ? slots[slots.length - 1].end : start).getTime() + 600 * MIN) : (parts.length ? parts[parts.length - 1].end : start);
        if (finish > due) sim.late += (finish - Math.max(due, start)) / MIN;
      }
    }
    return sim;
  }

  reason(item, energy, start) {
    const t = item.task;
    let base;
    switch (item.tier) {
      case TIER.overdue: base = 'Overdue — knock it out first'; break;
      case TIER.beforeMorning: base = `Due ${startOfDay(t.due).getTime() === startOfDay(start).getTime() ? 'today' : 'tomorrow'} at ${shortTime(t.due)}`; break;
      case TIER.tomorrow: base = 'Due tomorrow — get it done tonight'; break;
      case TIER.thisWeek: base = `Getting ahead — due ${t.due.toLocaleDateString([], { weekday: 'long' })}`; break;
      case TIER.later: base = `Getting ahead — due ${t.due.toLocaleDateString([], { month: 'short', day: 'numeric' })}`; break;
      default: base = 'No due date — chipping away at it';
    }
    if (item.warm) return 'Quick win to build momentum · ' + base;
    if (energy >= 0.7 && t.difficulty >= 3) base += " · hardest work while you're fresh";
    else if (energy < 0.6 && item.minutes <= 25) base += ' · lighter task for this time of day';
    return base;
  }

  /** busy: occurrences [{start,end,isAllDay,title,location}]; progress: {taskId: minutesDone} */
  makePlan(checkIn, tasks, busy, progress = {}) {
    const start = this.roundUp(checkIn);
    const [windowEnd, isLate] = this.workWindow(start);
    const busyBlocks = busy.filter(o => !o.isAllDay && o.end > start && o.start < windowEnd).sort((a, b) => a.start - b.start);
    const slots = this.freeSlots(start, windowEnd, busyBlocks);
    const items = tasks.filter(t => !t.isCompleted && !t.deleted)
      .map(t => ({ task: t, tier: this.tier(t.due, start), minutes: Math.max(5, t.estimatedMinutes - (progress[t.id] || 0)) }));
    const energy = this.energy(start);
    const smart = this.simulate(this.smartOrder(items, energy), slots, start, energy);
    const edf = this.simulate([...items].sort((a, b) => this.edf(a, b)), slots, start, energy);
    const useDeadline = smart.late > edf.late + 1;
    const chosen = useDeadline ? edf : smart;
    for (const o of busyBlocks) {
      chosen.blocks.push({ id: newId(), kind: 'event', title: o.title, subtitle: o.location || null, start: new Date(Math.max(o.start, start)), end: o.end, isDone: false });
    }
    chosen.blocks.sort((a, b) => (a.start - b.start) || ((a.kind === 'event' ? 0 : 1) - (b.kind === 'event' ? 0 : 1)));
    const strategy = !items.length ? 'Nothing on your plate — enjoy the free time.'
      : useDeadline ? 'Deadlines are tight, so this is ordered strictly by due time to keep everything on time.'
      : energy >= 0.7 ? "You checked in at a high-energy time: a quick win first, then the hardest work while you're fresh."
      : 'Lower-energy time of day: most important first, lighter and shorter tasks over heavy ones.';
    let summary = `Checked in at ${shortTime(checkIn)}`;
    if (chosen.work > 0) {
      summary += ` · ${durationText(chosen.work)} of focus`;
      if (chosen.finish) summary += ` · done around ${shortTime(chosen.finish)}`;
    }
    if (isLate) summary += " · it's late, so just the essentials";
    return { id: newId(), checkInAt: checkIn, windowEnd, blocks: chosen.blocks, overflowTaskIDs: chosen.overflow, summary, strategy, updatedAt: new Date(), deleted: false };
  }
}

module.exports = { Scheduler, durationText };
