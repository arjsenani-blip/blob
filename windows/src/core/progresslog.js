// Logging progress in plain words — port of BrainCore/ProgressLog.swift.
// "worked 45 min on the history essay", "finished the outline for my english essay", "got 92/100 on the chem lab".
'use strict';

function groups(pattern, s) {
  const m = new RegExp(pattern, 'i').exec(s);
  return m ? m.map(x => x ?? '') : null;
}
const clean = s => s.replace(/^(the|my|on|for|with)\s+/, '').replace(/\s+(today|tonight|just now|already|so far)$/, '').trim();

const WORDS = { a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, five: 5, 'half a': 0.5, 'half an': 0.5, 'a couple of': 2 };
function minutes(n, unit) {
  const v = isNaN(parseFloat(n)) ? WORDS[n] : parseFloat(n);
  if (v == null) return null;
  const m = Math.round(unit.startsWith('h') ? v * 60 : v);
  return m > 0 && m <= 16 * 60 ? m : null;
}
function letterPercent(l) {
  let v = { a: 95, b: 85, c: 75, d: 65, f: 50 }[l[0]] ?? 50;
  if (l.endsWith('+')) v += 3; else if (l.endsWith('-')) v -= 3;
  return v;
}
const STEP_WORDS = ['outline', 'draft', 'rough draft', 'final draft', 'intro', 'introduction', 'conclusion', 'research', 'sources',
  'bibliography', 'works cited', 'thesis', 'slides', 'study guide', 'practice test', 'review', 'notes', 'annotations',
  'data', 'analysis', 'graphs', 'write up', 'write-up', 'first part', 'part 1', 'part 2', 'part one', 'part two',
  'first half', 'second half', 'reading', 'body paragraph', 'paragraph', 'plan', 'script', 'poster', 'edit', 'editing', 'revisions', 'revise'];
const isStepWord = s => STEP_WORDS.some(w => s === w || s.startsWith(w + ' ') || s.endsWith(' ' + w) || (s.includes(w) && s.split(' ').length <= 3));

function grade(s) {
  const verb = String.raw`(?:got|scored|received|earned|get)\s+(?:an?\s+)?`;
  let m = groups(String.raw`^${verb}(\d+(?:\.\d+)?)\s*(?:/|out of)\s*(\d+(?:\.\d+)?)\s+(?:on|in|for)\s+(.+)$`, s);
  if (m && parseFloat(m[2]) > 0) return { kind: 'grade', earned: parseFloat(m[1]), possible: parseFloat(m[2]), query: clean(m[3]) };
  m = groups(String.raw`^${verb}(\d+(?:\.\d+)?)\s*(?:%|percent)?\s+(?:on|in|for)\s+(.+)$`, s);
  if (m && parseFloat(m[1]) <= 110) return { kind: 'grade', earned: parseFloat(m[1]), possible: 100, query: clean(m[2]) };
  m = groups(String.raw`^${verb}([abcdf][+-]?)\s+(?:on|in|for)\s+(.+)$`, s);
  if (m) return { kind: 'grade', earned: letterPercent(m[1]), possible: 100, query: clean(m[2]) };
  return null;
}

function worked(s) {
  const amount = String.raw`(\d+(?:\.\d+)?|an?|half an?|one|two|three|four|five|a couple of)\s*(hours?|hrs?|h|minutes?|mins?|m)\b`;
  const m = groups(String.raw`^(?:worked|spent|did|studied|put in|been working)\s+(?:on\s+(.+?)\s+for\s+)?(?:for\s+)?(?:about\s+|like\s+|around\s+)?${amount}(?:\s+(?:on|of|for|doing|working on|studying(?: for)?)\s+(.+))?$`, s);
  if (!m) return null;
  const mins = minutes(m[2], m[3]);
  if (mins == null) return null;
  let query = m[1] || m[4], note = null;
  const sep = /\s*(—|-|:|,)\s+/.exec(query);
  if (sep) { note = query.slice(sep.index + sep[0].length); query = query.slice(0, sep.index); }
  return { kind: 'worked', minutes: mins, query: clean(query), note };
}

/** → {kind: worked|finishedStep|completed|started|progress|grade|planSteps, ...} or null when it's not a log. */
function parseLog(input) {
  let text = input.trim().replace(/[.!]+$/, '');
  const saidLog = /^(hey |ok |okay )?(blob,?\s*)?(please |can you |could you )?(log|add|track)\s+\d/i.test(text);
  text = text.replace(/^(hey |ok |okay )?(blob,?\s*)?(please |can you |could you )?(log( that)?:?\s+|track\s+|mark( that)?\s+|note( that)?\s+)?/i, '');
  text = text.replace(/^(i('ve| have)?|i just|just)\s+/i, '');
  const lower = text.toLowerCase();
  if (/\b(due|by (mon|tue|wed|thu|fri|sat|sun|tomorrow|next|tonight)|tomorrow|tonight|next week)\b/.test(lower)
      && !/^(got|scored|received|worked|spent|did|studied)\b/.test(lower)) return null;

  const g = grade(lower); if (g) return g;
  let m = groups(String.raw`^(break|split)\s+(up\s+)?(.+?)\s+(up\s+)?into\s+(steps|parts|milestones|chunks)$`, lower);
  if (m) return { kind: 'planSteps', query: clean(m[3]) };
  m = groups(String.raw`^(plan out|make a plan for|make steps for|set up milestones for)\s+(.+)$`, lower);
  if (m) return { kind: 'planSteps', query: clean(m[2]) };

  const w = worked(lower) || (saidLog ? worked('worked ' + lower) : null); if (w) return w;

  m = groups(String.raw`^(?:i'?m |i am )?(halfway|half way|mostly|almost|nearly)\s+(?:done with|through|finished with)\s+(.+)$`, lower);
  if (m) return { kind: 'progress', percent: m[1].startsWith('half') ? 50 : 85, query: clean(m[2]) };
  m = groups(String.raw`^(.+?)\s+is\s+(\d{1,3})\s*%\s*(done|finished|complete)?$`, lower);
  if (m) return { kind: 'progress', percent: Math.min(100, +m[2]), query: clean(m[1]) };
  m = groups(String.raw`^(?:i'?m |i am )?(\d{1,3})\s*%\s*(?:done|through|finished)\s+(?:with\s+)?(.+)$`, lower);
  if (m) return { kind: 'progress', percent: Math.min(100, +m[1]), query: clean(m[2]) };

  m = groups(String.raw`^(finished|completed|wrapped up|done with|did|knocked out)\s+(?:the\s+|my\s+)?(.+?)\s+(?:for|of|on|in)\s+(?:the\s+|my\s+)?(.+)$`, lower);
  if (m && isStepWord(m[2])) return { kind: 'finishedStep', step: clean(m[2]), query: clean(m[3]) };

  m = groups(String.raw`^(finished|completed|turned in|submitted|handed in|done with|wrapped up)\s+(.+)$`, lower);
  if (m) return { kind: 'completed', query: clean(m[2]) };
  m = groups(String.raw`^(.+?)\s+is\s+(done|finished|complete|turned in|submitted)$`, lower);
  if (m) return { kind: 'completed', query: clean(m[1]) };
  m = groups(String.raw`^(started|began|starting|kicked off)\s+(on\s+|working on\s+)?(.+)$`, lower);
  if (m) return { kind: 'started', query: clean(m[3]) };
  return null;
}

// ---- Which assignment you meant ----

const STOP = new Set(['the', 'my', 'a', 'an', 'on', 'for', 'of', 'in', 'to', 'and', 'assignment', 'homework', 'hw', 'class', 'that', 'this', 'it']);
const ALIASES = {
  chem: ['chemistry'], bio: ['biology'], calc: ['calculus'], precalc: ['precalculus'], lang: ['language'], lit: ['literature'],
  gov: ['government'], econ: ['economics'], psych: ['psychology'], hist: ['history'], apush: ['history', 'us'], eng: ['english'],
  sci: ['science'], cs: ['computer', 'science'], pset: ['problem', 'set'], paper: ['essay'], essay: ['paper'], test: ['exam'], exam: ['test'],
};
const words = s => s.toLowerCase().split(/[^a-z0-9]+/).filter(w => w && !STOP.has(w));

function bestTask(query, tasks, fallbackId = null, now = new Date()) {
  const live = tasks.filter(t => !t.deleted);
  const q = words(query);
  if (!q.length) {
    if (fallbackId) { const f = live.find(t => t.id === fallbackId); if (f) return f; }
    return live.filter(t => !t.isCompleted).sort((a, b) => (a.due || Infinity) - (b.due || Infinity))[0] || null;
  }
  let best = null, bestScore = 0;
  for (const t of live) {
    const base = words(t.title + ' ' + (t.course || ''));
    const hay = new Set([...base, ...base.flatMap(w => ALIASES[w] || [])]);
    let score = 0;
    for (const w of q) {
      if (hay.has(w)) score += 1;
      else if ((ALIASES[w] || []).some(a => hay.has(a))) score += 0.9;
      else if (w.length >= 4 && [...hay].some(h => h.startsWith(w) || (w.startsWith(h) && h.length >= 4))) score += 0.7;
    }
    if (score <= 0) continue;
    score /= q.length;
    if (!t.isCompleted) score += 0.15;
    if (t.due) score += Math.max(0, 0.1 - Math.abs(t.due - now) / (86400e3 * 300));
    if (score > bestScore) { bestScore = score; best = t; }
  }
  return bestScore >= 0.5 ? best : null;
}

const overlap = (q, title) => { const t = new Set(words(title)); return q.filter(w => t.has(w) || [...t].some(x => x.startsWith(w) || w.startsWith(x))).length; };
function bestStep(query, task) {
  const q = words(query);
  if (!q.length) return (task.milestones || []).find(m => !m.isDone) || null;
  let best = null, score = 0;
  for (const m of task.milestones || []) { const s = overlap(q, m.title); if (s > score) { score = s; best = m; } }
  return best;
}

module.exports = { parseLog, bestTask, bestStep, overlap, words };
