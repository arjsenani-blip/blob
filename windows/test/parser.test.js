// Same cases as BrainCoreTests (ParserTests + AssignmentVsEventTests). Run with TZ=America/Los_Angeles.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { Parser } = require('../src/core/parser');

const now = new Date(2026, 9, 19, 10, 0);          // Monday, Oct 19 2026, 10:00
const d = (m, day, h = 0, min = 0) => new Date(2026, m - 1, day, h, min);
const parse = (s, courses = []) => new Parser({ now, courses }).parse(s);
const same = (a, b, msg) => assert.strictEqual(a && a.getTime(), b.getTime(), msg || `${a} vs ${b}`);

test('tomorrow at time', () => {
  const p = parse('Dentist tomorrow at 3pm');
  assert.strictEqual(p.kind, 'event'); assert.strictEqual(p.title, 'Dentist');
  same(p.start, d(10, 20, 15)); same(p.end, d(10, 20, 16));
});

test('recurring range with location', () => {
  const p = parse('soccer practice every tue and thu 5-7pm at Lincoln Field');
  assert.strictEqual(p.title, 'Soccer practice');
  assert.strictEqual(p.recurrence.frequency, 'weekly');
  assert.deepStrictEqual(p.recurrence.weekdays, [3, 5]);
  same(p.start, d(10, 20, 17)); same(p.end, d(10, 20, 19));
  assert.strictEqual(p.location, 'Lincoln Field');
});

test('task with due', () => {
  const p = parse('English essay due friday #school');
  assert.strictEqual(p.kind, 'task'); assert.strictEqual(p.title, 'English essay'); assert.strictEqual(p.tag, 'school');
  same(p.start, d(10, 23, 23, 59));
});

test('no date becomes task', () => {
  const p = parse('buy poster board');
  assert.strictEqual(p.kind, 'task'); assert.strictEqual(p.start, null); assert.strictEqual(p.title, 'Buy poster board');
});

test('next friday', () => same(parse('game next friday 7pm').start, d(10, 30, 19)));

test('month day all-day', () => {
  const p = parse('Halloween party oct 31');
  assert.ok(p.isAllDay); same(p.start, d(10, 31));
});

test('numeric date and duration', () => {
  const p = parse('SAT prep 11/7 9:30am for 2 hours');
  assert.strictEqual(p.title, 'SAT prep'); same(p.start, d(11, 7, 9, 30)); same(p.end, d(11, 7, 11, 30));
});

test('relative', () => {
  const p = parse('call mom in 2 hours');
  assert.strictEqual(p.title, 'Call mom'); same(p.start, d(10, 19, 12));
});

test('bare hour + @ location', () => {
  const p = parse('lunch with sam at noon @ Chipotle');
  same(p.start, d(10, 19, 12)); assert.strictEqual(p.location, 'Chipotle'); assert.strictEqual(p.title, 'Lunch with sam');
  same(parse('piano at 4').start, d(10, 19, 16));
});

test('past time rolls to tomorrow', () => same(parse('standup 9am').start, d(10, 20, 9)));
test('tonight', () => same(parse('movie tonight').start, d(10, 19, 20)));

test('title numbers survive; reading is an assignment', () => {
  const p = parse('read chapters 3-4 tomorrow');
  assert.strictEqual(p.title, 'Read chapters 3-4'); assert.strictEqual(p.kind, 'task');
});

test('ambiguous words stay in title', () => assert.strictEqual(parse('watch the sun rise tomorrow 6am').title, 'Watch the sun rise'));

test('every weekday', () => {
  const p = parse('bus every weekday 7:15am');
  assert.strictEqual(p.recurrence.frequency, 'weekdays'); same(p.start, d(10, 20, 7, 15));
});

test('task estimate', () => {
  const p = parse('todo lab report ~90m by thursday !!');
  assert.strictEqual(p.kind, 'task'); assert.strictEqual(p.title, 'Lab report'); assert.strictEqual(p.durationMinutes, 90);
  assert.strictEqual(p.priority, 2); same(p.start, d(10, 22, 23, 59));
});

test('range across noon', () => {
  const p = parse('study group sat 11-1pm');
  same(p.start, d(10, 24, 11)); same(p.end, d(10, 24, 13)); assert.strictEqual(p.title, 'Study group');
});

test('assignments become tasks', () => {
  const lab = parse('chem lab report friday');
  assert.strictEqual(lab.kind, 'task'); same(lab.start, d(10, 23, 23, 59)); assert.strictEqual(lab.course, 'Chemistry');
  for (const s of ['study for math test thursday', 'read chapter 7 for APUSH tomorrow', 'final draft english essay tuesday', 'do the calc worksheet tonight']) {
    assert.strictEqual(parse(s).kind, 'task', s);
  }
  const proj = parse('history project monday 8am');
  assert.strictEqual(proj.kind, 'task'); same(proj.start, d(10, 26, 8));
});

test('events stay events', () => {
  for (const s of ['soccer practice friday 5pm', 'math test friday', 'dentist tomorrow 3pm', 'chem study group thu 4-5pm', 'SAT prep class every saturday 9am']) {
    assert.strictEqual(parse(s).kind, 'event', s);
  }
});

test('known courses from Classroom', () => {
  const p = parse('lang essay due fri', ['AP Language & Composition (P2)', 'AP Calculus BC']);
  assert.strictEqual(p.kind, 'task'); assert.strictEqual(p.course, 'AP Language & Composition (P2)');
  assert.strictEqual(parse('calc problem set tomorrow', ['AP Calculus BC']).course, 'AP Calculus BC');
});
