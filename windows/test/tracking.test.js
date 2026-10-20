// Long-term tracking and progress logging — mirrors TrackingTests and ProgressLogTests in BrainCore.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Scheduler } = require('../src/core/scheduler');
const { task, defaultSettings, decodeDoc, encodeDoc, emptyDoc } = require('../src/core/model');
const tr = require('../src/core/tracking');
const { parseLog, bestTask, bestStep } = require('../src/core/progresslog');
const { Store } = require('../src/store');

const d = (m, day, h = 0) => new Date(2026, m - 1, day, h);
const ms = (title, due, est, isDone = false) => ({ id: title, title, due, estimatedMinutes: est, isDone });

test('suggested steps fit before the due date', () => {
  const steps = tr.suggestSteps('History research essay', d(10, 19, 16), d(11, 2, 23), 300);
  assert.equal(steps[0].title, 'Research & sources');
  assert.equal(steps.length, 5);
  assert.equal(+steps[4].due, +d(11, 2, 23));
  assert.ok(steps.slice(0, -1).every(s => s.due <= d(11, 1, 23)));
  assert.equal(steps.reduce((a, s) => a + s.estimatedMinutes, 0), 300);
});

test('progress and pace', () => {
  const t = task({ title: 'Essay', due: d(10, 31, 23), startDate: d(10, 17), createdAt: d(10, 17),
    milestones: [ms('A', d(10, 22), 60), ms('B', d(10, 27), 120), ms('C', d(10, 31), 60)] });
  assert.ok(tr.isLongTerm(t));
  assert.equal(tr.pace(t, d(10, 18)), 'notStarted');
  assert.equal(tr.pace(t, d(10, 24)), 'behind');
  t.milestones[0].isDone = true;
  assert.equal(tr.progress(t), 0.25);
  assert.equal(tr.pace(t, d(10, 18)), 'ahead');
  assert.equal(tr.pace(t, d(10, 20)), 'onTrack');
  assert.equal(tr.remainingMinutes(t), 180);
  assert.equal(tr.pace(t, d(11, 1)), 'overdue');
});

test('grade average is point-weighted', () => {
  const s = tr.courseSummaries([task({ title: 'Quiz', course: 'Chem', isCompleted: true, pointsEarned: 9, maxPoints: 10 }),
                                task({ title: 'Test', course: 'Chem', isCompleted: true, pointsEarned: 70, maxPoints: 100 })])[0];
  assert.ok(Math.abs(s.averageGrade - 79 / 110 * 100) < 0.01);
});

test("planner does today's share of a big project", () => {
  const p = task({ title: 'Science fair project', due: d(10, 30, 23), estimatedMinutes: 600, createdAt: d(10, 15) });
  const plan = new Scheduler(defaultSettings()).makePlan(d(10, 19, 16), [p], []);
  const work = plan.blocks.filter(b => b.kind === 'task');
  const mins = work.reduce((a, b) => a + (b.end - b.start) / 60000, 0);
  assert.ok(mins >= 50 && mins < 120, `got ${mins}`);
  assert.ok(work.every(b => b.sessionOnly === true));
});

test('planner works on the next step', () => {
  const e = task({ title: 'Essay', due: d(10, 30, 23), milestones: [ms('Outline', d(10, 20, 21), 40), ms('Draft', d(10, 28), 90)] });
  const work = new Scheduler(defaultSettings()).makePlan(d(10, 19, 16), [e], []).blocks.filter(b => b.kind === 'task');
  assert.equal(work[0].title, 'Essay — Outline');
  assert.equal(work[0].milestoneID, 'Outline');
  assert.equal(work.reduce((a, b) => a + (b.end - b.start) / 60000, 0), 40);
});

test('workload spreads over days', () => {
  const days = tr.workloadPerDay([task({ title: 'Big', due: d(10, 23, 23), estimatedMinutes: 240 })], d(10, 19, 9), 7);
  assert.deepEqual(days.slice(0, 5).map(x => x.minutes), [60, 60, 60, 60, 0]);
});

test('log sentences', () => {
  assert.deepEqual(parseLog('worked 45 min on the history essay'), { kind: 'worked', minutes: 45, query: 'history essay', note: null });
  assert.deepEqual(parseLog('I spent 2 hours on my chem lab'), { kind: 'worked', minutes: 120, query: 'chem lab', note: null });
  assert.deepEqual(parseLog('worked on the science fair project for 1.5 hours'), { kind: 'worked', minutes: 90, query: 'science fair project', note: null });
  assert.deepEqual(parseLog('Hey Blob, log 30 minutes on english essay - wrote the intro'), { kind: 'worked', minutes: 30, query: 'english essay', note: 'wrote the intro' });
  assert.deepEqual(parseLog('finished the outline for my english essay'), { kind: 'finishedStep', step: 'outline', query: 'english essay' });
  assert.deepEqual(parseLog('turned in the chem lab'), { kind: 'completed', query: 'chem lab' });
  assert.deepEqual(parseLog('got 92/100 on the chem lab'), { kind: 'grade', earned: 92, possible: 100, query: 'chem lab' });
  assert.deepEqual(parseLog('got an A- on my essay'), { kind: 'grade', earned: 92, possible: 100, query: 'essay' });
  assert.deepEqual(parseLog("I'm halfway through the english essay"), { kind: 'progress', percent: 50, query: 'english essay' });
  assert.deepEqual(parseLog('break the science project into steps'), { kind: 'planSteps', query: 'science project' });
  assert.equal(parseLog('finish the essay by friday'), null);
  assert.equal(parseLog('history essay due friday'), null);
  assert.equal(parseLog('read chapter 4'), null);
});

test('matching assignments and steps', () => {
  const essay = task({ title: 'Unit 3 DBQ Essay', course: 'AP World History', due: new Date(Date.now() + 5 * 86400e3),
                       milestones: [ms('Research & sources'), ms('Outline'), ms('Rough draft')] });
  const lab = task({ title: 'Titration Lab Report', course: 'Chemistry Honors', due: new Date(Date.now() + 2 * 86400e3) });
  const quiz = task({ title: 'Vocab quiz 7', course: 'Spanish 3' });
  assert.equal(bestTask('history essay', [essay, lab, quiz]).id, essay.id);
  assert.equal(bestTask('chem lab', [essay, lab, quiz]).id, lab.id);
  assert.equal(bestTask('piano recital', [essay, lab, quiz]), null);
  assert.equal(bestStep('rough draft', essay).title, 'Rough draft');
});

test('store: add long-term, log, finish steps, and the file round-trips with the Swift format', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'blob-'));
  const s = new Store(dir);
  const due = new Date(Date.now() + 12 * 86400e3);
  s.add({ kind: 'task', title: 'History project long-term', course: 'History', start: due, priority: 1 });
  const t = s.tasks[0];
  assert.equal(t.title, 'History project');
  assert.ok(t.milestones.length >= 3);
  assert.match(s.applyLog('worked 45 min on the history project'), /Logged 45m on History project/);
  assert.match(s.applyLog('finished the plan for the history project'), /Checked off/);
  const again = decodeDoc(encodeDoc(s.doc)).tasks[0];
  assert.equal(again.sessions[0].minutes, 45);
  assert.ok(again.milestones[0].isDone);
  assert.equal(+again.milestones[1].due, +s.tasks[0].milestones[1].due);
  assert.ok(again.startDate instanceof Date);
});
