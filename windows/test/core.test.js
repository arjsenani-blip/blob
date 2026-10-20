// Scheduler, sync and file-format tests — mirrors BrainCoreTests and checks compatibility with the Swift apps.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Scheduler } = require('../src/core/scheduler');
const { task, event, stableId, emptyDoc, decodeDoc, encodeDoc, occurrences, defaultSettings } = require('../src/core/model');
const { merge } = require('../src/core/merge');

const d = (day, h, m = 0) => new Date(2026, 9, day, h, m);
const S = () => new Scheduler(defaultSettings());

test('orders and avoids events', () => {
  const tasks = [
    task({ title: 'Essay', course: 'English', due: d(23, 23, 59), estimatedMinutes: 90, difficulty: 3 }),
    task({ title: 'Math HW', course: 'Math', due: d(19, 23, 59), estimatedMinutes: 40 }),
    task({ title: 'Vocab quiz', course: 'Spanish', due: d(20, 8), estimatedMinutes: 15, difficulty: 1 }),
    task({ title: 'Done thing', due: d(19, 23), isCompleted: true }),
  ];
  const practice = { title: 'Practice', start: d(19, 17), end: d(19, 18), isAllDay: false };
  const plan = S().makePlan(d(19, 15, 32), tasks, [practice]);
  const work = plan.blocks.filter(b => b.kind === 'task');
  assert.strictEqual(work[0].title, 'Vocab quiz');
  assert.strictEqual(work[0].start.getTime(), d(19, 15, 35).getTime());
  assert.ok(work.some(b => b.title === 'Math HW'));
  assert.ok(!work.some(b => b.title === 'Done thing'));
  for (const b of work) assert.ok(!(b.start < practice.end && b.end > practice.start), `${b.title} overlaps practice`);
  assert.ok(plan.blocks.some(b => b.kind === 'event' && b.title === 'Practice'));
  assert.strictEqual(plan.overflowTaskIDs.length, 0);
  assert.ok(plan.blocks.every(b => b.end <= d(19, 22, 30)));
});

test('falls back to deadline order', () => {
  const plan = S().makePlan(d(19, 15, 30), [
    task({ title: 'Hard project', due: d(19, 23, 59), estimatedMinutes: 60, difficulty: 3 }),
    task({ title: 'Form', due: d(19, 16, 30), estimatedMinutes: 30 }),
  ], []);
  assert.strictEqual(plan.blocks.find(b => b.kind === 'task').title, 'Form');
});

test('late check-in is short', () => {
  const plan = S().makePlan(d(19, 23, 10), [task({ title: 'Big essay', due: d(20, 8), estimatedMinutes: 180 })], []);
  assert.ok(plan.blocks.filter(b => b.kind === 'task').reduce((s, b) => s + (b.end - b.start) / 60000, 0) <= 60);
  assert.strictEqual(plan.overflowTaskIDs.length, 1);
});

test('breaks between long work, never ends on a break', () => {
  const plan = S().makePlan(d(19, 16), [task({ title: 'Project', due: d(20, 9), estimatedMinutes: 120 })], []);
  assert.ok(plan.blocks.some(b => b.kind === 'breakTime'));
  assert.strictEqual(plan.blocks.filter(b => b.kind === 'task').reduce((s, b) => s + (b.end - b.start) / 60000, 0), 120);
  for (let m = 0; m < 60; m += 7) {
    const p = S().makePlan(d(19, 20, m), [task({ title: 'A', due: d(20, 8), estimatedMinutes: 120 }), task({ title: 'B', due: d(20, 23), estimatedMinutes: 90 })], []);
    assert.notStrictEqual(p.blocks[p.blocks.length - 1].kind, 'breakTime');
  }
});

test('newest wins, tombstones propagate', () => {
  const old = task({ title: 'Old', updatedAt: new Date(Date.now() - 100000) });
  const newer = { ...old, title: 'New', updatedAt: new Date() };
  const gone = task({ title: 'Gone', deleted: true });
  const m = merge({ ...emptyDoc(), tasks: [old, gone] }, { ...emptyDoc(), tasks: [newer] });
  assert.strictEqual(m.tasks.find(t => t.id === old.id).title, 'New');
  assert.ok(m.tasks.find(t => t.id === gone.id).deleted);
});

test('stable Classroom ids match the Swift apps exactly', () => {
  assert.strictEqual(stableId('classroom:1:2'), '5C1A529A-A55A-5671-BED2-12FB195F4410');
  assert.strictEqual(stableId('classroom:123456:789'), '98295580-5D72-5025-940B-5899BDA052E3');
});

test('recurring expansion', () => {
  const start = d(20, 17);
  const e = event({ title: 'Soccer', start, end: new Date(start.getTime() + 7200e3), recurrence: { frequency: 'weekly', weekdays: [3, 5] } });
  assert.strictEqual(occurrences(e, d(19, 0), d(33, 0)).length, 4);
});

test('reads and re-saves a real Mac data file unchanged', () => {
  const file = path.join(os.homedir(), 'Library/Application Support/ArjunsBrain/brain.json');
  if (!fs.existsSync(file)) return;
  const raw = fs.readFileSync(file, 'utf8');
  assert.deepStrictEqual(JSON.parse(encodeDoc(decodeDoc(raw))), JSON.parse(raw));
});
