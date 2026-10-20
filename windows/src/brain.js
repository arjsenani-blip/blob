// Blob's brain on Windows: instant commands (free, offline), then Claude through Claude Code on the user's
// Pro plan — kept running in the background and streamed, so Blob starts talking as Claude writes.
'use strict';
const os = require('os');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');
const sys = require('./system');
const { dueText, shortTime } = require('./core/dates');

const PERSONA = 'You are Blob, a refined British AI butler — think JARVIS — who lives as a glowing cyan blob in the corner of the user\'s Windows PC. '
  + 'Always address the user as "sir". Be calm, precise and quietly witty; never gushing. You speak out loud, so reply in one to three short spoken '
  + 'sentences: no markdown, no lists, no emoji, and don\'t read URLs aloud. The user is a high school student — for homework, guide and explain rather '
  + 'than writing the assignment for them. In this mode you can\'t operate the PC; if asked to, tell them to ask it as a direct command, like "open YouTube". '
  + 'Use web search for anything current. Answer directly — no preamble.';

class Brain {
  constructor(store) {
    this.store = store;
    this.proc = null;
    this.buf = '';
    this.turn = null;
    this.lastUse = 0;
    this.claudePath = undefined;
  }

  async findClaude() {
    if (this.claudePath !== undefined) return this.claudePath;
    const candidates = process.platform === 'win32'
      ? [path.join(os.homedir(), '.local/bin/claude.exe'), path.join(process.env.APPDATA || '', 'npm/claude.cmd'), path.join(process.env.LOCALAPPDATA || '', 'Programs/claude/claude.exe')]
      : [path.join(os.homedir(), '.local/bin/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude'];
    let found = candidates.find(p => p && fs.existsSync(p)) || null;
    if (!found) {
      found = await new Promise(r => execFile(process.platform === 'win32' ? 'where' : 'which', ['claude'], { windowsHide: true },
        (e, out) => r(!e && out.trim() ? out.trim().split(/\r?\n/)[0] : null)));
    }
    this.claudePath = found;
    return found;
  }

  /** Start the Claude session early (called when the user starts talking). */
  warmUp() { this.ensure().catch(() => {}); }

  async ensure() {
    if (this.proc && !this.proc.killed && this.proc.exitCode === null) return true;
    const claude = await this.findClaude();
    if (!claude) return false;
    const cwd = path.join(os.homedir(), '.blob-claude-chat');       // empty folder: Claude here can only talk and search
    fs.mkdirSync(cwd, { recursive: true });
    const args = ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
                  '--model', 'sonnet', '--append-system-prompt', PERSONA, '--allowedTools', 'WebSearch', 'WebFetch',
                  '--disallowedTools', 'Bash', 'Edit', 'Write', 'Read', 'Glob', 'Grep'];
    this.proc = spawn(claude, args, { cwd, windowsHide: true, shell: claude.endsWith('.cmd') });
    this.buf = '';
    this.proc.stdout.on('data', d => this.onData(d));
    this.proc.on('exit', () => { this.proc = null; if (this.turn) { this.turn.reject(new Error('Claude stopped.')); this.turn = null; } });
    return true;
  }

  onData(chunk) {
    this.buf += chunk.toString('utf8');
    let nl;
    while ((nl = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, nl); this.buf = this.buf.slice(nl + 1);
      let e; try { e = JSON.parse(line); } catch { continue; }
      if (!this.turn) continue;
      if (e.type === 'stream_event' && e.event?.type === 'content_block_delta' && e.event.delta?.type === 'text_delta') {
        this.turn.text += e.event.delta.text;
        this.turn.onPartial(this.turn.text);
      } else if (e.type === 'result') {
        const t = this.turn; this.turn = null; clearTimeout(t.timer);
        const final = (e.result || t.text || '').trim();
        e.is_error || !final ? t.reject(new Error(final || 'No answer.')) : t.resolve(final);
      }
    }
  }

  async askClaude(text, onPartial) {
    if (Date.now() - this.lastUse > 15 * 60e3 && this.proc) this.proc.kill();   // fresh conversation after a break
    this.lastUse = Date.now();
    if (!(await this.ensure())) throw new Error('Claude Code isn\'t installed on this PC, sir.');
    const ctx = `[Now: ${new Date().toLocaleString([], { weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' })}]`;
    return new Promise((resolve, reject) => {
      this.turn = { text: '', onPartial, resolve, reject, timer: setTimeout(() => { this.turn = null; reject(new Error('It took too long.')); this.proc?.kill(); }, 90_000) };
      this.proc.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: ctx + '\n' + text }] } }) + '\n');
    });
  }

  /** Main entry: returns the reply; streams Claude's partial text through onPartial. */
  async respond(raw, onPartial = () => {}) {
    const quick = await this.local(raw);
    if (quick) return quick;
    try {
      return await this.askClaude(raw.replace(/^(?:ask claude|think (?:harder|hard) about)[,:]?\s*/i, ''), onPartial);
    } catch (e) {
      // No Claude (or offline): still understand "add …" style requests.
      const p = this.store.parse(raw);
      if (p.start || /^(?:remind me to|add|todo|schedule)\b/i.test(raw)) {
        this.store.add(p);
        return `Added ${p.title}${p.start ? (p.kind === 'task' ? ', due ' : ' for ') + dueText(p.start, p.hasExplicitTime) : ''}, sir.`;
      }
      return `${e.message} I can still open apps and sites, play YouTube and music, search, control volume, set timers and manage your planner.`;
    }
  }

  async local(raw) {
    let t = raw.toLowerCase().trim().replace(/[.!?]+$/, '');
    t = t.replace(/^(?:hey blob|blob|ok blob)[, ]+/, '').replace(/^(?:can you |could you |please |would you )+/, '').replace(/[ ,]*(?:please|for me|thanks|thank you)$/, '');
    const m = re => t.match(re);
    let g;

    if ((g = m(/^(?:play|put on|watch|find) (.+?) on youtube$|^youtube (.+)$|^play (?:the )?(?:youtube )?video (?:of |for |about )?(.+)$/))) {
      await sys.playYouTube(g[1] || g[2] || g[3]); return 'Here you are, sir.';
    }
    if ((g = m(/^(?:search|look up) youtube (?:for )?(.+)$|^search for (.+) on youtube$/))) { sys.searchWeb(g[1] || g[2], 'youtube'); return 'YouTube results are up, sir.'; }
    if ((g = m(/^play (.+?) on (spotify|youtube music)$/))) return (await sys.playMusic(g[1], g[2] === 'spotify' ? 'spotify' : null)) + ' Enjoy, sir.';
    if ((g = m(/^(?:play|put on) (?:some |the song |the album |music by |songs by )?(.+)$/)) && !['music', 'the music', 'it', 'something', 'next', 'previous'].includes(g[1])) {
      return (await sys.playMusic(g[1])) + ' Enjoy, sir.';
    }
    if ((g = m(/^(?:search|google|look up|search the web|search google)(?: for)? (.+?)(?: on (google|amazon|wikipedia|reddit|maps|images))?$/))) {
      sys.searchWeb(g[1], g[2]); return 'Here are the results, sir.';
    }
    if ((g = m(/^(?:open|go to|pull up|launch|show me|start) (?:the )?(.+?)(?: website| site| app)?$/))) {
      const name = sys.openApp(g[1]);
      if (name) return `Opening ${name}, sir.`;
      if (sys.SITES[g[1]]) { sys.openUrl(sys.SITES[g[1]]); return `Opening ${g[1].replace(/\b\w/g, c => c.toUpperCase())}, sir.`; }
      if (/^[a-z0-9-]+\.[a-z.]{2,}(\/\S*)?$/.test(g[1])) { sys.openUrl('https://' + g[1]); return `Opening ${g[1]}, sir.`; }
    }
    if ((g = m(/^(?:quit|close) (?:the )?(.+?)(?: app)?$/)) && await sys.quitApp(g[1])) return 'Closed, sir.';
    if (m(/^(?:mute|unmute|be quiet|silence)(?: the)?(?: sound| volume| audio)?$/)) { await sys.volume.mute(); return 'Done, sir.'; }
    if ((g = m(/^(?:set )?(?:the )?volume (?:to )?(\d{1,3})(?: percent| %)?$/))) { await sys.volume.set(+g[1]); return `Volume at ${Math.min(100, +g[1])} percent, sir.`; }
    if ((g = m(/^(?:turn )?(?:the )?volume (up|down)$|^(louder|quieter|turn it up|turn it down)$/))) {
      const up = g[1] === 'up' || g[2] === 'louder' || g[2] === 'turn it up';
      await (up ? sys.volume.up() : sys.volume.down()); return up ? 'Louder, sir.' : 'Quieter, sir.';
    }
    if (m(/^(?:pause|stop|play|resume)(?: the)?(?: music| song| playback| video)?$/)) { await sys.media.playPause(); return 'Done, sir.'; }
    if (m(/^(?:next|skip)(?: song| track| this)?$/)) { await sys.media.next(); return 'Next track, sir.'; }
    if (m(/^(?:previous|go back|last)(?: song| track)?$/)) { await sys.media.prev(); return 'Going back, sir.'; }
    if (m(/^what(?:'s| is) the time|^what time is it/)) return `It's ${shortTime(new Date())}, sir.`;
    if (m(/^what(?:'s| is) (?:the date|today'?s date)|^what day is (?:it|today)/)) return `It's ${new Date().toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })}, sir.`;
    if ((g = m(/^(?:set (?:a )?)?timer (?:for )?(\d+(?:\.\d+)?) ?(minutes?|mins?|hours?|seconds?|secs?)$/))) {
      const n = +g[1], u = g[2]; sys.timer(u.startsWith('h') ? n * 3600 : u.startsWith('s') ? n : n * 60);
      return `Timer set for ${g[1]} ${u}, sir.`;
    }
    if (m(/^(?:check (?:me )?in|let'?s (?:get to work|start working)|plan my (?:day|night|evening|afternoon))$/)) {
      const plan = this.store.checkIn();
      const first = plan.blocks.find(b => b.kind === 'task');
      return first ? `You're checked in, sir. First up: ${first.title} at ${shortTime(first.start)}.` : 'Checked in, sir. Nothing\'s due — the evening is yours.';
    }
    if (m(/^what(?:'s| is) (?:on )?my (?:schedule|calendar|day)|^what do i have(?: today)?$/)) {
      const now = new Date();
      const ev = this.store.occurrencesOn(now).filter(o => !o.isAllDay && o.end > now).slice(0, 3).map(o => `${o.title} at ${shortTime(o.start)}`);
      const due = this.store.dueOn(now).filter(x => !x.isCompleted);
      if (!ev.length && !due.length) return 'Nothing else on the books today, sir.';
      if (due.length) ev.push(`${due.length} assignment${due.length === 1 ? '' : 's'} due`);
      return `Today you have ${ev.join(', ')}, sir.`;
    }
    if ((g = m(/^what(?:'s| is) due|^what (?:homework|assignments) do i have/))) {
      const open = this.store.pending.filter(x => x.due).sort((a, b) => a.due - b.due).slice(0, 3);
      return open.length ? `Next up: ${open.map(x => `${x.title}, ${dueText(x.due)}`).join('; ')}, sir.` : 'Nothing due, sir.';
    }
    // Quick add: "remind me to…", "add…", or anything with a date that reads like an event or assignment.
    if (/^(?:remind me to|add|todo|schedule|put)\b/i.test(raw)) {
      const p = this.store.parse(raw.replace(/^(?:add|put|schedule)\s+/i, '').replace(/\s+(?:to|on|in) my (?:calendar|planner|list)/i, ''));
      this.store.add(p);
      return `Added ${p.title}${p.start ? (p.kind === 'task' ? ', due ' : ' for ') + dueText(p.start, p.hasExplicitTime) : ''}, sir.`;
    }
    return null;
  }
}

module.exports = { Brain };
