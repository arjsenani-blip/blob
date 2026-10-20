// Local-time date helpers, plus conversion to the Swift apps' date format so the synced file is shared as-is.
'use strict';

const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds());
const at = (day, [h, m]) => new Date(day.getFullYear(), day.getMonth(), day.getDate(), h, m, 0, 0);
/** Calendar weekday like Swift's: 1 = Sunday … 7 = Saturday. */
const weekdayOf = d => d.getDay() + 1;
const sameDay = (a, b) => startOfDay(a).getTime() === startOfDay(b).getTime();

// Swift's JSONEncoder writes dates as seconds since 1 Jan 2001 (UTC).
const REF = Date.UTC(2001, 0, 1);
const toSwift = d => (d == null ? undefined : (d.getTime() - REF) / 1000);
const fromSwift = s => (s == null ? null : new Date(REF + s * 1000));

const shortTime = d => d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

/** "Today 3:00 PM", "Tomorrow", "Fri 11:59 PM", "Oct 31" — same wording as the Mac app. */
function dueText(d, includeTime = true) {
  const now = new Date();
  const time = includeTime ? ' ' + shortTime(d) : '';
  const days = Math.round((startOfDay(d) - startOfDay(now)) / 86400000);
  if (days === 0) return 'Today' + time;
  if (days === 1) return 'Tomorrow' + time;
  if (days === -1) return 'Yesterday' + time;
  if (days > 0 && days < 7) return d.toLocaleDateString([], { weekday: 'short' }) + time;
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + time;
}

module.exports = { startOfDay, addDays, at, weekdayOf, sameDay, toSwift, fromSwift, shortTime, dueText };
