// Long-term assignment tracking — port of BrainCore/Tracking.swift: progress, pace, steps, per-class summaries, workload ahead.
'use strict';
const { startOfDay, addDays, at } = require('./dates');
const { newId } = require('./model');

const DAY = 86400e3;
const sum = (xs, f) => xs.reduce((a, x) => a + f(x), 0);

const loggedMinutes = t => { const s = sum(t.sessions || [], x => x.minutes); return s > 0 ? s : (t.actualMinutes || 0); };
const totalEstimate = t => (t.milestones?.length ? Math.max(5, sum(t.milestones, m => m.estimatedMinutes)) : t.estimatedMinutes);
const nextMilestone = t => (t.milestones || []).find(m => !m.isDone) || null;

function remainingMinutes(t) {
  if (t.isCompleted) return 0;
  if (t.milestones?.length) {
    const open = t.milestones.filter(m => !m.isDone);
    if (!open.length) return 5;
    const onFirst = sum((t.sessions || []).filter(s => s.milestoneID === open[0].id), s => s.minutes);
    return Math.max(5, sum(open, m => m.estimatedMinutes) - Math.min(onFirst, open[0].estimatedMinutes - 5));
  }
  return Math.max(5, t.estimatedMinutes - loggedMinutes(t));
}

function progress(t) {
  if (t.isCompleted) return 1;
  if (t.milestones?.length) {
    let done = sum(t.milestones.filter(m => m.isDone), m => m.estimatedMinutes);
    // Partial credit for time already put into the step you're on.
    const step = nextMilestone(t);
    if (step) done += Math.min(sum((t.sessions || []).filter(s => s.milestoneID === step.id), s => s.minutes), step.estimatedMinutes * 0.9);
    return Math.min(0.97, done / Math.max(totalEstimate(t), 1));
  }
  return Math.min(0.9, loggedMinutes(t) / Math.max(t.estimatedMinutes, 1));
}

const isLongTerm = t => (t.milestones?.length ? true : totalEstimate(t) >= 120);
const percentGrade = t => (t.pointsEarned != null && t.maxPoints > 0 ? t.pointsEarned / t.maxPoints * 100 : null);
const effectiveStart = t => t.startDate || t.createdAt || (t.due ? new Date(t.due - 14 * DAY) : null);

function expectedProgress(t, now = new Date()) {
  const start = effectiveStart(t);
  if (!t.due || !start || t.due <= start) return null;
  return Math.min(1, Math.max(0, (now - start) / ((t.due - start) * 0.9)));
}

/** Whole days to work, keeping the due day as a buffer when there's room. */
function workDays(now, due) {
  const days = Math.round((startOfDay(due) - startOfDay(now)) / DAY);
  return Math.max(1, days >= 3 ? days : days + 1);
}

function minutesPerDayNeeded(t, now = new Date()) {
  if (t.isCompleted || !t.due || t.due <= now) return null;
  return Math.ceil(remainingMinutes(t) / workDays(now, t.due));
}

const PACE_LABEL = { done: 'Done', ahead: 'Ahead', onTrack: 'On track', behind: 'Behind', atRisk: 'At risk', overdue: 'Overdue', notStarted: 'Not started' };

function pace(t, now = new Date()) {
  if (t.isCompleted) return 'done';
  if (!t.due) return loggedMinutes(t) > 0 || (t.milestones || []).some(m => m.isDone) ? 'onTrack' : 'notStarted';
  if (t.due < now) return 'overdue';
  const perDay = minutesPerDayNeeded(t, now);
  if (perDay != null && perDay > 150) return 'atRisk';
  if ((t.milestones || []).some(m => !m.isDone && m.due && m.due < now)) return 'behind';
  const expected = expectedProgress(t, now);
  if (expected == null) return 'onTrack';
  const actual = progress(t);
  if (actual <= 0.001 && expected < 0.15) return 'notStarted';
  if (actual >= expected + 0.15) return 'ahead';
  if (actual < expected - 0.2) return expected - actual > 0.45 ? 'atRisk' : 'behind';
  return 'onTrack';
}

// ---- Breaking a big assignment into steps ----

function suggestSteps(title, start, due, totalMinutes) {
  const t = title.toLowerCase();
  const has = (...w) => w.some(x => t.includes(x));
  let steps;
  if (has('essay', 'paper', 'report', 'dbq', 'writing', 'research', 'thesis'))
    steps = [['Research & sources', 0.2], ['Outline', 0.15], ['Rough draft', 0.35], ['Revise & edit', 0.2], ['Final read-through & submit', 0.1]];
  else if (has('test', 'exam', 'final', 'midterm', 'quiz', 'ap ', 'sat', 'act'))
    steps = [['Make a study guide', 0.25], ['Review weak topics', 0.3], ['Practice test', 0.3], ['Final review', 0.15]];
  else if (has('presentation', 'slides', 'speech'))
    steps = [['Research', 0.25], ['Build the slides', 0.4], ['Practice out loud', 0.25], ['Final polish', 0.1]];
  else if (has('lab'))
    steps = [['Organize data', 0.25], ['Analysis & graphs', 0.3], ['Write it up', 0.3], ['Check & submit', 0.15]];
  else if (has('project', 'portfolio', 'model', 'build', 'video'))
    steps = [['Plan & research', 0.2], ['Build the main part', 0.45], ['Finish & polish', 0.25], ['Submit', 0.1]];
  else if (has('read', 'book', 'novel', 'chapters'))
    steps = [['Read the first third', 0.33], ['Read the middle', 0.33], ['Finish & take notes', 0.34]];
  else steps = [['Get started', 0.25], ['Main work', 0.5], ['Finish & check', 0.25]];

  const span = due - start;
  const buffer = span > 4 * DAY ? DAY : span * 0.1;
  const end = new Date(due - buffer);
  const usable = Math.max(end - start, 3600e3);
  let cum = 0;
  return steps.map(([name, share], i) => {
    cum += share;
    const last = i === steps.length - 1;
    let date = last ? due : new Date(start.getTime() + usable * cum);
    if (!last && span > 2 * DAY) { date = at(date, [21, 0]); if (date > end) date = end; }
    return { id: newId(), title: name, due: date, estimatedMinutes: Math.max(10, Math.round(totalMinutes * share / 5) * 5), isDone: false };
  });
}

function defaultEstimate(title) {
  const t = title.toLowerCase();
  const has = (...w) => w.some(x => t.includes(x));
  if (has('science fair', 'final project', 'portfolio', 'research paper', 'thesis')) return 600;
  if (has('project', 'presentation')) return 360;
  if (has('essay', 'paper', 'report', 'dbq')) return 300;
  if (has('final', 'midterm', 'exam', 'ap test')) return 360;
  if (has('study for', 'test')) return 180;
  if (has('book', 'novel')) return 300;
  if (has('lab report')) return 180;
  return null;
}

function looksLongTerm(title, due, now = new Date(), explicit = false) {
  if (explicit) return true;
  if (!due || due - now < 4 * DAY) return false;
  return defaultEstimate(title) != null;
}

// ---- Per class & workload ----

function courseSummaries(tasks, now = new Date()) {
  const live = tasks.filter(t => !t.deleted);
  const groups = {};
  for (const t of live) (groups[(t.course || '').trim() || 'Other'] ||= []).push(t);
  return Object.entries(groups).map(([name, ts]) => {
    const open = ts.filter(t => !t.isCompleted);
    const graded = ts.filter(t => percentGrade(t) != null);
    const earned = sum(graded, t => t.pointsEarned), possible = sum(graded, t => t.maxPoints);
    const upcoming = open.map(t => t.due).filter(d => d && d >= now).sort((a, b) => a - b);
    return {
      name, openCount: open.length, overdueCount: open.filter(t => t.due && t.due < now).length,
      longTermCount: open.filter(isLongTerm).length, completedCount: ts.length - open.length,
      remainingMinutes: sum(open, remainingMinutes), loggedMinutes: sum(ts, loggedMinutes),
      averageGrade: possible > 0 ? earned / possible * 100 : null, gradedCount: graded.length, nextDue: upcoming[0] || null,
    };
  }).sort((a, b) => (a.name === 'Other') - (b.name === 'Other') || a.name.localeCompare(b.name));
}

function workloadPerDay(tasks, now = new Date(), days = 14) {
  const today = startOfDay(now);
  const buckets = new Array(days).fill(0);
  const spreadFrom = (from, minutes, due) => {
    if (minutes <= 0) return;
    if (!due || due <= from) { buckets[0] += minutes; return; }
    const n = workDays(from, due);
    const offset = Math.round((startOfDay(from) - today) / DAY);
    for (let i = 0; i < n; i++) if (offset + i >= 0 && offset + i < days) buckets[offset + i] += Math.round(minutes / n);
  };
  for (const t of tasks) {
    if (t.deleted || t.isCompleted) continue;
    if (!t.milestones?.length) { spreadFrom(now, remainingMinutes(t), t.due || addDays(today, 7)); continue; }
    let from = now;
    for (const m of t.milestones.filter(x => !x.isDone)) {
      const due = m.due || t.due;
      if (due && due > from) { spreadFrom(from, m.estimatedMinutes, due); from = due; } else buckets[0] += m.estimatedMinutes;
    }
  }
  return buckets.map((minutes, i) => ({ day: addDays(today, i), minutes }));
}

module.exports = {
  loggedMinutes, totalEstimate, nextMilestone, remainingMinutes, progress, isLongTerm, percentGrade, expectedProgress,
  minutesPerDayNeeded, workDays, pace, PACE_LABEL, suggestSteps, defaultEstimate, looksLongTerm, courseSummaries, workloadPerDay,
};
