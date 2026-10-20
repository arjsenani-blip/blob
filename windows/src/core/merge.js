// Sync merge — port of BrainCore/SyncMerger.swift: newest edit of each record wins, tombstones and old plans are pruned.
'use strict';

function mergeRecords(a, b) {
  const byId = new Map();
  for (const r of [...a, ...b]) {
    const ex = byId.get(r.id);
    if (ex && ex.updatedAt >= r.updatedAt) continue;
    byId.set(r.id, r);
  }
  return [...byId.values()];
}

function merge(local, remote, now = new Date()) {
  const tomb = now.getTime() - 60 * 86400e3, planCut = now.getTime() - 14 * 86400e3;
  const byIdThen = (k) => (x, y) => (k(x) - k(y)) || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0);
  return {
    schemaVersion: 1,
    events: mergeRecords(local.events, remote.events).filter(e => !(e.deleted && e.updatedAt < tomb)).sort(byIdThen(e => e.start.getTime())),
    tasks: mergeRecords(local.tasks, remote.tasks).filter(t => !(t.deleted && t.updatedAt < tomb)).sort(byIdThen(t => (t.due ? t.due.getTime() : 8.64e15))),
    plans: mergeRecords(local.plans, remote.plans).filter(p => p.checkInAt > planCut).sort((x, y) => x.checkInAt - y.checkInAt),
    settings: local.settings.updatedAt >= remote.settings.updatedAt ? local.settings : remote.settings,
  };
}

module.exports = { merge, mergeRecords };
