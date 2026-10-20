// The safe bridge between Blob's windows and the main process.
'use strict';
const { contextBridge, ipcRenderer } = require('electron');

const call = ch => (...a) => ipcRenderer.invoke(ch, ...a);
const on = ch => fn => { const h = (_e, ...a) => fn(...a); ipcRenderer.on(ch, h); return () => ipcRenderer.removeListener(ch, h); };

contextBridge.exposeInMainWorld('blob', {
  state: call('state'), occurrences: call('occurrences'), parse: call('parse'), add: call('add'),
  upsertTask: call('upsertTask'), toggleTask: call('toggleTask'), deleteTask: call('deleteTask'),
  upsertEvent: call('upsertEvent'), deleteEvent: call('deleteEvent'),
  checkIn: call('checkIn'), startBlock: call('startBlock'), completeBlock: call('completeBlock'),
  updateSettings: call('updateSettings'), setPrefs: call('setPrefs'),
  ask: call('ask'), warmUp: call('warmUp'), transcribe: call('transcribe'), speak: call('speak'), voiceDownload: call('voiceDownload'),
  googleSignIn: call('googleSignIn'), googleSignOut: call('googleSignOut'), syncNow: call('syncNow'), classroomNow: call('classroomNow'),
  logPreview: call('logPreview'), taskLog: call('taskLog'), taskSay: call('taskSay'), stepToggle: call('stepToggle'), stepAdd: call('stepAdd'),
  stepUpdate: call('stepUpdate'), stepDelete: call('stepDelete'), planSteps: call('planSteps'), setGrade: call('setGrade'), markDone: call('markDone'),
  deleteSession: call('deleteSession'), connectCalendar: call('connectCalendar'), calendarNow: call('calendarNow'),
  overlayInteractive: call('overlayInteractive'), overlayFocus: call('overlayFocus'), openBrain: call('openBrain'), micAccess: call('micAccess'),
  onState: on('state-changed'), onActivate: on('activate'), onPartial: on('brain-partial'), onVoiceProgress: on('voice-progress'), onStage: on('stage'),
});
