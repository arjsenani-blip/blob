// Natural-language quick add — a line-by-line port of BrainCore/NaturalLanguageParser.swift,
// so "soccer every tue 5-7pm at Field 3" or "essay due fri" means the same on Windows as on Mac and iPhone.
'use strict';
const { startOfDay, addDays, at, weekdayOf } = require('./dates');

const ASSIGNMENT = /\b(home ?work|hw|assignment|essay|worksheet|problem ?set|pset|practice (problems|questions|set|test)|lab (report|write ?up)|write ?up|project|reading|read (ch|chapter|pages|pp)|chapters?|paper|report|study ?guide|study for|review for|notes|outline|rough draft|final draft|draft|annotations?|exercises|packet|journal|reflection|flashcards|vocab (list|cards|words)|discussion post|turn in|submit|finish|complete|do (the|my)|frq|dbq|leq|saq|lab\b)/;
const EVENT = /\b(practice|game|match|meet|meeting|appointment|appt|dentist|doctor|orthodontist|party|class|club|rehearsal|concert|recital|tryouts?|lesson|dinner|lunch|breakfast|movie|trip|flight|interview|tournament|session|test|exam|quiz|midterm|finals?(?!\s*draft)|ap exam|ceremony|assembly|conference|shift|work)\b/;
const SUBJECTS = [
  [/\b(ap )?calc(ulus)?\b/, 'Calculus'], [/\b(pre-?calc|precalculus)\b/, 'Precalculus'], [/\b(math|algebra|geometry|stats|statistics)\b/, 'Math'],
  [/\b(chem|chemistry)\b/, 'Chemistry'], [/\b(bio|biology)\b/, 'Biology'], [/\bphysics\b/, 'Physics'],
  [/\b(ap )?lang\b/, 'AP Lang'], [/\b(ap )?lit\b/, 'AP Lit'], [/\benglish\b/, 'English'],
  [/\b(apush|us history)\b/, 'APUSH'], [/\b(world history|history)\b/, 'History'], [/\b(gov|government|civics)\b/, 'Government'],
  [/\b(econ|economics)\b/, 'Economics'], [/\b(psych|psychology)\b/, 'Psychology'], [/\bspanish\b/, 'Spanish'], [/\bfrench\b/, 'French'],
  [/\b(cs|computer science|apcsa|csp)\b/, 'Computer Science'],
];

const WEEKDAYS = 'monday|mon|tuesday|tues|tue|wednesday|weds|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun';
const MONTHS = 'january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec';
const TIME = String.raw`(?:(\d{1,2})(?::(\d{2}))?\s*(a\.m\.|p\.m\.|am|pm|a|p)?|(noon|midnight))`;
const LEAD = String.raw`(?:(?:on|by)\s+)?`;

function weekdayNumber(word) {
  const w = (word || '').toLowerCase();
  const table = [['sun', 1], ['mon', 2], ['tue', 3], ['wed', 4], ['thu', 5], ['fri', 6], ['sat', 7]];
  const hit = table.find(([p]) => w.startsWith(p));
  return hit ? hit[1] : null;
}
function monthNumber(word) {
  const names = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  const i = names.findIndex(n => (word || '').toLowerCase().startsWith(n));
  return i < 0 ? null : i + 1;
}
function number(word) {
  const w = (word || '').toLowerCase().trim();
  if (/^\d+(\.\d+)?$/.test(w)) return parseFloat(w);
  return { a: 1, an: 1, one: 1, two: 2, 'a couple of': 2, 'couple of': 2, three: 3, 'a few': 3, few: 3, four: 4, five: 5, 'half a': 0.5, 'half an': 0.5 }[w.replace(/\s+/g, ' ')] ?? null;
}
function minutes(amount, unit) {
  const u = unit.toLowerCase();
  if (u.startsWith('h')) return Math.round(amount * 60);
  if (u.startsWith('d')) return Math.round(amount * 1440);
  if (u.startsWith('w')) return Math.round(amount * 10080);
  return Math.round(amount);
}

class Parser {
  constructor({ now = new Date(), courses = [] } = {}) {
    this.now = now;
    this.courses = courses;
  }

  detectCourse(text) {
    const lower = text.toLowerCase();
    for (const c of [...this.courses].sort((a, b) => b.length - a.length)) {
      if (!c) continue;
      if (lower.includes(c.toLowerCase())) return c;
      const core = c.toLowerCase().split(/[(\-–:|]/)[0].trim();
      if (core.length >= 4 && lower.includes(core)) return c;
    }
    for (const [re, name] of SUBJECTS) {
      if (re.test(lower)) return this.courses.find(c => c.toLowerCase().includes(name.toLowerCase())) || name;
    }
    return null;
  }

  // Finds the first match passing `validate`, removes it from state.text, returns groups (lowercased unless caseSensitive).
  take(state, pattern, { caseSensitive = false, validate = () => true } = {}) {
    const re = new RegExp(pattern, 'gu' + (caseSensitive ? '' : 'i'));
    for (const m of state.text.matchAll(re)) {
      const groups = Array.from(m, g => (g === undefined ? null : g));
      const lowered = groups.map(g => (g == null ? null : g.toLowerCase()));
      if (!validate(lowered)) continue;
      state.text = state.text.slice(0, m.index) + ' ' + state.text.slice(m.index + m[0].length);
      return caseSensitive ? groups : lowered;
    }
    return null;
  }

  nextWeekday(weekday, includeToday) {
    const today = startOfDay(this.now);
    let diff = (weekday - weekdayOf(today) + 7) % 7;
    if (diff === 0 && !includeToday) diff = 7;
    return addDays(today, diff);
  }

  isInCurrentWeek(date) {
    const today = startOfDay(this.now);
    const iso = (weekdayOf(today) + 5) % 7 + 1;           // Mon=1 … Sun=7
    return date < addDays(today, 8 - iso);
  }

  makeDate(month, day, year) {
    if (!month || !day || month < 1 || month > 12 || day < 1 || day > 31) return null;
    const today = startOfDay(this.now);
    let date = new Date(year ?? today.getFullYear(), month - 1, day);
    if (year == null && date < addDays(today, -1)) date = new Date(today.getFullYear() + 1, month - 1, day);
    return date;
  }

  parseTime(hour, minute, meridiem, word) {
    if (word) return word === 'noon' ? [12, 0] : [0, 0];
    const h = hour != null ? parseInt(hour, 10) : NaN;
    if (Number.isNaN(h) || h > 23) return null;
    const m = minute != null ? parseInt(minute, 10) : 0;
    if (m >= 60) return null;
    if (meridiem != null && (h === 0 || h > 12)) return null;
    return [h, m];
  }

  resolveHour(h, meridiem, evening) {
    if (meridiem) {
      const pm = meridiem.startsWith('p');
      if (h === 12) return pm ? 12 : 0;
      return pm ? h + 12 : h;
    }
    if (h >= 13 || h === 0) return h;
    if (h === 12) return 12;
    if (evening) return h + 12;
    return h >= 1 && h <= 6 ? h + 12 : h;      // bare "at 3" → afternoon, "at 9" → morning
  }

  static cleanTitle(raw) {
    let s = raw.replace(/\s+/g, ' ').trim();
    const dangling = /^(on|at|from|for|in|by|due|to|-|–|,|\.)\s+|\s+(on|at|from|for|in|by|due|to|starting|-|–|,|\.)$/i;
    let prev = '';
    while (prev !== s) {
      prev = s;
      s = s.replace(dangling, '').replace(/^[\s,.\-–]+|[\s,.\-–]+$/g, '');
    }
    if (s && s[0] !== s[0].toUpperCase()) s = s[0].toUpperCase() + s.slice(1);
    return s;
  }

  parse(input) {
    const state = { text: ' ' + input.replace(/\n/g, ' ') + ' ' };
    const lowerInput = input.toLowerCase();
    const looksLikeAssignment = ASSIGNMENT.test(lowerInput);
    const looksLikeEvent = EVENT.test(lowerInput) && !/\b(study|review) for\b/.test(lowerInput);
    const now = this.now;
    const today = startOfDay(now);

    let forcedTask = false, tag = null, priority = 1, recurrence = { frequency: 'none', weekdays: [] };
    let relativeStart = null, relativeHasTime = false, duration = null, day = null;
    let startTime = null, endTime = null, startHadMeridiem = false, endHadMeridiem = false, timeHint = null, dayIsBareWeekday = false;
    const evening = /\b(tonight|evening|night|dinner|pm)\b/i.test(state.text);
    const take = (p, o) => this.take(state, p, o);

    // Tag and priority
    let g;
    if ((g = take(String.raw`(?<=\s)#([\p{L}\p{N}_-]+)`, { caseSensitive: true }))) tag = g[1];
    if (take(String.raw`(?<=\s)(!{1,3}|!high|!urgent)(?=\s)`)) priority = 2;
    if (take(String.raw`(?<=\s)(!low)(?=\s)`)) priority = 0;

    // Explicit task markers
    if (take(String.raw`^\s*(todo:?|to-do:?|task:|remind me to|reminder:|hw:)\s`)) forcedTask = true;
    if (take(String.raw`\sdue(\s+(on|by|at))?(?=\s)`)) forcedTask = true;
    if (new RegExp(String.raw`\sby\s+(today|tonight|tomorrow|tmrw|next|this|${WEEKDAYS}|${MONTHS}|\d)`, 'i').test(state.text)) forcedTask = true;

    // Recurrence
    if (take(String.raw`\b(every\s?day|daily|each day)\b`)) recurrence = { frequency: 'daily', weekdays: [] };
    else if (take(String.raw`\b(on\s+)?(every\s+weekday|weekdays)\b`)) recurrence = { frequency: 'weekdays', weekdays: [] };
    else if ((g = take(String.raw`\bevery\s+((?:(?:${WEEKDAYS})(?:day)?s?\.?(?:\s*(?:,|and|&|/)\s*)?)+)`))) {
      const days = (g[1] || '').split(/[^a-z]+/).filter(Boolean).map(weekdayNumber).filter(Boolean);
      recurrence = { frequency: 'weekly', weekdays: [...new Set(days)].sort((a, b) => a - b) };
    } else if ((g = take(String.raw`\b(?:on\s+)?(mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays)\b`))) {
      recurrence = { frequency: 'weekly', weekdays: [weekdayNumber(g[1])].filter(Boolean) };
    } else if (take(String.raw`\b(every\s+week|weekly)\b`)) recurrence = { frequency: 'weekly', weekdays: [] };
    else if (take(String.raw`\b(every\s+month|monthly)\b`)) recurrence = { frequency: 'monthly', weekdays: [] };
    const repeating = recurrence.frequency !== 'none';

    // "in 20 minutes", "in 3 days"
    if ((g = take(String.raw`\bin\s+(\d+(?:\.\d+)?|an?|one|two|three|a\s+couple\s+of|a\s+few)\s+(minutes?|mins?|hours?|hrs?|days?|weeks?)\b`))) {
      const amount = number(g[1]);
      if (amount != null) {
        relativeStart = new Date(now.getTime() + minutes(amount, g[2]) * 60000);
        relativeHasTime = g[2].startsWith('m') || g[2].startsWith('h');
      }
    }

    // Durations
    if ((g = take(String.raw`\bfor\s+(\d+)\s*h(?:ours?|rs?)?\s*(\d+)\s*m(?:in(?:ute)?s?)?\b`))) duration = parseInt(g[1]) * 60 + parseInt(g[2]);
    else if ((g = take(String.raw`\bfor\s+(\d+(?:\.\d+)?|an?|one|two|three|half\s+an?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b`)) && number(g[1]) != null) duration = minutes(number(g[1]), g[2]);
    else if ((g = take(String.raw`(?<=\s)~\s*(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b`))) duration = minutes(parseFloat(g[1]), g[2]);
    else if ((g = take(String.raw`\b(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?)\s+long\b`))) duration = minutes(parseFloat(g[1]), g[2]);

    // Dates
    if (take(String.raw`\b${LEAD}(the\s+)?day\s+after\s+tomorrow\b`)) day = addDays(today, 2);
    else if (take(String.raw`\b${LEAD}(tomorrow|tmrw|tmr|tmw|tomorow|tommorow|tommorrow)\b`)) day = addDays(today, 1);
    else if (take(String.raw`\b${LEAD}(today|tdy)\b`)) day = today;
    else if (take(String.raw`\b${LEAD}next\s+week\b`)) { const d = this.nextWeekday(2, false); day = this.isInCurrentWeek(d) ? addDays(d, 7) : d; }
    else if (take(String.raw`\b${LEAD}(this\s+)?weekend\b`)) day = this.nextWeekday(7, true);
    else if (take(String.raw`\b${LEAD}next\s+month\b`)) day = new Date(today.getFullYear(), today.getMonth() + 1, 1);
    else if ((g = take(String.raw`\b${LEAD}(${MONTHS})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b`))) day = this.makeDate(monthNumber(g[1]), parseInt(g[2]), g[3] ? parseInt(g[3]) : null);
    else if ((g = take(String.raw`\b${LEAD}(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(${MONTHS})\b(?:,?\s+(\d{4}))?`))) day = this.makeDate(monthNumber(g[2]), parseInt(g[1]), g[3] ? parseInt(g[3]) : null);
    else if ((g = take(String.raw`(?<![\d/])${LEAD}(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])`))) {
      let year = g[3] ? parseInt(g[3]) : null;
      if (year != null && year < 100) year += 2000;
      day = this.makeDate(parseInt(g[1]), parseInt(g[2]), year);
    } else if ((g = take(String.raw`\b${LEAD}(next|this)?\s*(${WEEKDAYS})\b\.?(?=(\s+(?:at\s+)?\d)?)`, {
      validate: gr => {
        const ambiguous = ['sat', 'sun', 'wed'].includes(gr[2]);
        return !ambiguous || gr[1] != null || (gr[0] || '').includes('on ') || (gr[0] || '').includes('by ') || gr[3] != null;
      },
    }))) {
      const wd = weekdayNumber(g[2]);
      if (wd) {
        if (g[1] === 'next') { const d = this.nextWeekday(wd, false); day = this.isInCurrentWeek(d) ? addDays(d, 7) : d; }
        else { day = this.nextWeekday(wd, true); dayIsBareWeekday = true; }
      }
    } else if ((g = take(String.raw`\b${LEAD}the\s+(\d{1,2})(?:st|nd|rd|th)\b`))) {
      let c = new Date(today.getFullYear(), today.getMonth(), parseInt(g[1]));
      if (c < today) c = new Date(today.getFullYear(), today.getMonth() + 1, parseInt(g[1]));
      day = c;
    }

    // Time ranges
    const range = String.raw`(?<![\d/:])(from\s+)?${TIME}\s*(?:-|–|—|to|until|till)\s*${TIME}(?![\d/:])\b`;
    if ((g = take(range, { validate: gr => gr[4] != null || gr[8] != null || gr[3] != null || gr[7] != null || gr[5] != null || gr[9] != null || gr[1] != null }))) {
      const s = this.parseTime(g[2], g[3], g[4], g[5]);
      const e = this.parseTime(g[6], g[7], g[8], g[9]);
      if (s && e) {
        startHadMeridiem = g[4] != null || g[5] != null;
        endHadMeridiem = g[8] != null || g[9] != null;
        if (!startHadMeridiem && endHadMeridiem && g[8]) {
          const inherited = this.resolveHour(s[0], g[8], evening);
          const endHour = this.resolveHour(e[0], g[8], evening);
          s[0] = inherited <= endHour ? inherited : this.resolveHour(s[0], 'am', false);
          startHadMeridiem = true;
        } else if (!startHadMeridiem) s[0] = this.resolveHour(s[0], null, evening);
        if (g[8] != null) e[0] = this.resolveHour(e[0], g[8], evening);
        else if (g[9] == null) e[0] = e[0] < 12 && s[0] >= 12 && e[0] + 12 > s[0] ? e[0] + 12 : this.resolveHour(e[0], null, evening);
        startTime = s; endTime = e;
      }
    } else if ((g = take(String.raw`(?:\b(at|@)\s*)?(?<![\d/:])${TIME}(?![\d/:])\b`, { validate: gr => gr[4] != null || gr[3] != null || gr[5] != null || (gr[1] != null && gr[2] != null) }))) {
      const t = this.parseTime(g[2], g[3], g[4], g[5]);
      if (t) {
        startHadMeridiem = g[4] != null || g[5] != null;
        if (g[5] == null) t[0] = this.resolveHour(t[0], g[4], evening);
        startTime = t;
      }
    }

    // Fuzzy times of day
    if ((g = take(String.raw`\b(?:this\s+|in\s+the\s+)?(morning|afternoon|evening|tonight|night)\b`))) {
      timeHint = { morning: [9, 0], afternoon: [14, 0], evening: [18, 0] }[g[1]] || [20, 0];
      if (!['morning', 'afternoon', 'evening'].includes(g[1]) && !day) day = today;
    }

    // Location
    let location = null;
    if ((g = take(String.raw`\s@\s*([^@]+?)\s*$`, { caseSensitive: true }))) location = g[1];
    else if ((g = take(String.raw`\s(?:at|in)\s+((?:the\s+)?[A-Z0-9][^@]*?)\s*$`, { caseSensitive: true }))) location = g[1];
    else if ((g = take(String.raw`\sat\s+(the\s+[^@]+?)\s*$`, { caseSensitive: true }))) location = g[1];
    if (location) location = Parser.cleanTitle(location) || null;

    const result = {
      kind: 'event', title: Parser.cleanTitle(state.text), start: null, end: null, isAllDay: false, hasExplicitTime: false,
      location, tag, recurrence, durationMinutes: duration, priority, course: null,
    };

    if (relativeStart) {
      if (relativeHasTime && !startTime) {
        const r = new Date(relativeStart);
        r.setSeconds(0, 0);
        r.setMinutes(r.getMinutes() + (5 - (r.getMinutes() % 5)) % 5);
        day = startOfDay(r);
        startTime = [r.getHours(), r.getMinutes()];
      } else if (!day) day = startOfDay(relativeStart);
    }

    if (!day && repeating) {
      if (recurrence.frequency === 'weekly' && recurrence.weekdays.length) {
        day = recurrence.weekdays.map(w => this.nextWeekday(w, true)).sort((a, b) => a - b)[0];
      } else if (recurrence.frequency === 'weekdays') {
        for (let i = 0; i < 7; i++) { const d = addDays(today, i); const w = weekdayOf(d); if (w >= 2 && w <= 6) { day = d; break; } }
      } else day = today;
    }

    const time = startTime || timeHint;
    if (dayIsBareWeekday && day && startOfDay(day).getTime() === today.getTime() && startTime && at(day, startTime) <= now) day = addDays(day, 7);
    if (repeating && startTime && day && time && at(day, time) <= now) {
      const d0 = day;
      for (let i = 1; i <= 31; i++) {
        const c = addDays(d0, i), wd = weekdayOf(c);
        const ok = recurrence.frequency === 'daily' ? true
          : recurrence.frequency === 'weekdays' ? wd >= 2 && wd <= 6
          : recurrence.frequency === 'weekly' ? (recurrence.weekdays.length ? recurrence.weekdays.includes(wd) : wd === weekdayOf(d0))
          : c.getDate() === d0.getDate();
        if (ok) { day = c; break; }
      }
    }
    if (!day && time) day = at(today, time) > now ? today : addDays(today, 1);

    const assignmentByContext = looksLikeAssignment && !looksLikeEvent && !endTime && !repeating;
    const isTask = forcedTask || assignmentByContext || (!day && !time && !repeating);
    result.course = this.detectCourse(input);
    result.kind = isTask ? 'task' : 'event';
    result.hasExplicitTime = startTime != null;
    if (!day) return result;

    if (isTask) {
      result.start = time ? at(day, time) : at(day, [23, 59]);
      return result;
    }
    if (time) {
      const s = at(day, time);
      result.start = s;
      if (endTime) {
        let end = at(day, endTime);
        if (end <= s) end = !endHadMeridiem && end.getTime() + 12 * 3600e3 > s.getTime() ? new Date(end.getTime() + 12 * 3600e3) : addDays(end, 1);
        result.end = end;
        result.durationMinutes = Math.round((end - s) / 60000);
      } else result.end = new Date(s.getTime() + (duration ?? 60) * 60000);
    } else {
      result.isAllDay = true;
      result.start = day;
      result.end = addDays(day, 1);
    }
    return result;
  }
}

module.exports = { Parser };
