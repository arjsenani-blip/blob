# Blob 🫧

*(formerly Arjun's Brain — the main window is **Blob's Brain**)*

One app for your calendar, assignments, and a timeline for what to do right now. It's a native SwiftUI app for **Mac** and **iPhone/iPad** built from the same code, so both look and work the same way.

## What it does

| | |
|---|---|
| **Quick add** | Type normally and a live preview shows how it'll be saved. `Dentist tomorrow 3pm` · `Soccer every tue & thu 5-7pm @ Lincoln Field` · `Essay due fri ~90m #English` · `Call grandma in 2 hours` · `todo buy poster board !!`. It runs on-device, so you don't need an API key. |
| **Calendar** | Month grid plus a day agenda. Events can repeat (daily, weekdays, weekly on chosen days, or monthly), and you can delete a single repeat. Shows your Apple Calendar and Google Calendar events too. |
| **Long-term tracker** | Big assignments (projects, essays, studying for a test) get **dated steps**, a **work log**, **progress**, and a **pace**: ahead, on track, behind or at risk. Add one with `History project due nov 20 long-term`, or it happens automatically for big work. Assignments has **Upcoming / Long-term / Classes / Done** views: a 2-week workload chart, grade averages per class, and a detail page for every assignment. |
| **Log in plain English** | Type it, or just tell Blob: `worked 45 min on the history essay` · `finished the outline for my english essay` · `got 92/100 on the chem lab` · `history project is 60% done` · `break the science project into steps`. Ask Blob *"am I on track?"* or *"how's my history project going?"* |
| **Apple Calendar** (Mac + iPhone) | Assignments show up **as tasks in the Calendar app**, through a *Blob* list in Reminders. Ticking one off there marks it done in Blob. Blob's events can go into a *Blob* calendar. Turn it on in Settings → Apple Calendar. |
| **Google Calendar** | Shows the calendars you have on in Google Calendar. It can add Blob's events to your Google Calendar, and add assignments as **Google Tasks**, which show as tasks in Google Calendar. Ticking one off there marks it done in Blob. |
| **Google Classroom** | Pulls in assignments from your active classes, with due dates, turned-in and late status, and **grades** once they're returned. It keeps a semester of graded history and splits big assignments into steps automatically. Read-only: it never changes anything in Classroom. |
| **Check in** | Builds a timeline from now until bedtime: it skips around your events, adds breaks, and orders work by urgency and by the time of day you checked in. Long-term assignments get their **next step** or **today's share**, so they move forward a bit every day instead of all the night before. Anything that won't fit gets flagged. Pressing ▶ / ✓ logs how long you actually took. |
| **Sync** | Mac and iPhone sync through a hidden app-data folder in Google Drive. If you edit on both, each item keeps the newest edit. |
| **Mac extras** | Menu-bar panel for quick add and up next, plus ⌘K quick add, ⌘I check in, and ⌘R sync. Reminders before events and when each work block starts. |

## Blob, your voice assistant (Mac)

Blob is the glowing cyan blob tucked into the bottom-right corner of your screen. It speaks like a British AI butler and calls you "sir".

**Talk to it**
- **Tap the fn (🌐) key** on its own, then say your request. Or click Blob.
- Set *System Settings → Keyboard → "Press 🌐 key to" → Do Nothing* so macOS doesn't also open the emoji picker. Blob needs Accessibility permission to see the fn key.
- Blob doesn't listen in the background: the microphone only turns on after you tap fn or click Blob.
- Right-click Blob to type instead of talking.

**Free by default, mostly offline**

| Part | Runs | Costs |
|---|---|---|
| Speech recognition and voice | On your Mac, offline | Free |
| Brain (default): Apple Intelligence | On your Mac, offline | Free |
| Instant commands (open apps and sites, YouTube, music, search, volume, timers, schedule, check-in) | On your Mac | Free. YouTube and web pages need internet. |
| Controlling app buttons, menus and typing (Accessibility) | On your Mac, offline | Free |
| "Ask Claude …" (one question to Claude) | Claude Code on your **Pro plan**, needs internet | No extra charge; counts toward your Pro usage |
| Optional "Claude API" brain (screenshot-based screen control) | Internet | **Paid per use.** Off unless you choose it and add a key. |

**Things to try:** tap fn, then say…
- "play Interstellar soundtrack on YouTube"
- "search for chem lab safety rules"
- "open Gmail"
- "play Drake on Spotify"
- "volume 30"
- "pause"
- "what's on my schedule"
- "check me in"
- "I worked an hour on the science fair project"
- "am I on track?"
- "set a timer for 25 minutes"
- "what's on my screen?"
- "click the Sign In button"
- "ask Claude why the sky is blue"

**Voice:** Blob speaks as **Chatterbox Daniel**: a calm British voice that sounds the most human. It runs entirely on your Mac and is free.
- The voice model stays loaded while Blob runs, which uses about 3 GB of memory.
- It takes about 20 seconds to warm up after launch. Until then, Blob uses the faster Kokoro Daniel voice.
- Replies start a few seconds slower than with Kokoro.
- You can switch to **Kokoro**, which is fast, or to **Apple**'s voice in Settings → Voice.
- The voice files live in `~/Library/Application Support/ArjunsBrain/Voice`. Chatterbox comes from Resemble AI (MIT license) and adds an inaudible watermark marking its audio as AI-generated. Kokoro is Apache-2.0.

**Permissions:** macOS asks for these the first time each is needed. Settings → *What Blob can do* has shortcuts to each.
- Microphone and Speech Recognition, so Blob can hear you.
- Accessibility, so it can click, type and use menus.
- Screen Recording, so it can read your screen.

**Battery:** there's no always-on microphone. Blob's animation slows down when it's tucked away or asleep, and stops when it's hidden. On battery, Blob uses the lighter Kokoro voice instead of Chatterbox, unless you turn on "Use the natural voice on battery" in Settings.

**Updating Blob with Claude Code:** tap fn and say "update yourself to …", use **Update Blob…** (right-click Blob, or the menu bar), or go to Settings → *Blob updates*. While it works, Blob's bubble shows Claude Code's progress live.
1. You approve the request with a click.
2. Claude Code edits this project folder and rebuilds it. It's limited to file edits and build commands, and runs on your Pro plan with no extra charge.
3. Blob shows you a summary and the list of changed files. Nothing installs until you click **Allow** a second time. If you say no, the code is put back the way it was.
4. The previous app and code are backed up. Say "undo the last update" to go back.

Blob's AI can never start an update by itself. The project folder has to stay in a permanent place for this to work; it's shown in Settings → *Blob updates* and can be changed there.

Blob is Mac-only. iPhones don't allow an app to control the rest of the phone.

## Blob for Windows

The `windows/` folder is the Windows version: the corner Blob plus the **Blob's Brain** planner. It uses the same synced data as the Mac and iPhone.

- **Install:** run `Blob-Setup-1.1.0.exe` from the [latest release](https://github.com/arjsenani-blip/blob/releases/latest). The installer isn't code-signed, so Windows shows "Windows protected your PC" the first time. Click **More info → Run anyway**.
- **Talk:** press **Ctrl+Shift+B** anywhere, or click Blob in the bottom-right corner. Right-click Blob to open Blob's Brain. Blob also lives in the system tray.
- **Voice:** the first time you talk, Blob offers to download its offline voice and hearing (about 380 MB, one time). It uses the same Daniel voice as the Mac, and Moonshine for speech recognition, both running on your PC. Until then you can type, and Blob answers with Windows' built-in voice.
- **Brain:** instant commands work offline: open apps and sites, YouTube, music, search, volume and media keys, timers, schedule, check-in, adding assignments and events. Everything else goes to **Claude Code on your Pro plan** (install Claude Code on the PC and sign in). Replies stream, so Blob starts talking right away.
- **Sync:** in Settings, paste a **Desktop app** OAuth client ID and secret from the same Google Cloud project as your Mac, then sign in. Data syncs with the Mac and iPhone through the same hidden Drive file.
- **Build it yourself:**

  ```bash
  cd windows && npm install && npm test && npm run dist
  ```

  This makes `windows/dist/Blob-Setup-<version>.exe`. It builds on a Mac too.
- **Tracker & calendars:** the long-term tracker, plain-English logging (typed or spoken), Google Calendar and Google Tasks all work on Windows too. Apple Calendar is Mac and iPhone only.

---

## 1. Install on your Mac

Download **`Blob.dmg`** from the [latest release](https://github.com/arjsenani-blip/blob/releases/latest), open it, and drag the app into Applications (replace the old one when updating). The first time, right-click Blob → Open, because the app isn't notarized.

To rebuild after changing code, run `./scripts/build_dmg.sh` (it needs Xcode and `brew install xcodegen`).

## 2. Install on your iPhone (sideload, free Apple ID)

1. Plug your iPhone into the Mac and tap **Trust**.
2. Open the project:
   ```bash
   open ArjunsBrain.xcodeproj
   ```
3. At the top of Xcode, choose the **ArjunsBrain-iOS** scheme and select your iPhone as the device.
4. Under **Signing & Capabilities** for the iOS target, pick your team ("Arjun Senani (Personal Team)").
5. Press **▶ Run**.
6. The first time, go to iPhone **Settings → General → VPN & Device Management**, tap your Apple ID, and choose **Trust**.
7. If the iPhone asks, turn on **Developer Mode** (Settings → Privacy & Security) and restart.

> With a free Apple ID the app **expires after 7 days**. To renew it, plug in and press ▶ Run again. Your data stays because it syncs through Drive. A paid developer account ($99/yr) extends this to a year.

## 3. One-time Google setup (~5 min)

Google needs an ID for the app before it can read Classroom or Drive:

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a project called *Blob*.
2. **APIs & Services → Library**: enable **Google Classroom API**, **Google Drive API**, **Google Calendar API** and **Google Tasks API**.
3. **OAuth consent screen**: choose External, enter the app name and your email. Under **Test users**, add your **school email** and your personal Gmail.
4. **Credentials → Create credentials → OAuth client ID**, type **iOS**, bundle ID `com.arjunsenani.brain`.
5. Copy the client ID and paste it into **Settings → Google setup** in the app, on both the Mac and the iPhone.
6. On both devices, go to **Settings → Google Classroom → Sign in with Google** and use your school account.
7. For Google Calendar: in **Settings → Google Calendar**, click **Connect Google Calendar** on the account whose calendar you use, then pick what to sync.

**If your school account gets blocked:** some school Google admins don't allow outside apps. If Classroom sign-in fails, ask your school's IT to allow the app (there's no way around that part). If Classroom works but Drive is blocked, sign a personal Gmail into **Separate sync account** on both devices.

> While the Google project is in "Testing" mode, Google signs you out about every 7 days. When that happens, tap Sign in again.

## How the check-in planner decides

1. **Time window:** from now until your "done working by" time (default 10:30 PM). If you check in after that, you get a short 60-minute session for the essentials only.
2. **Urgency:** overdue → due before tomorrow morning → due tomorrow → this week → later.
3. **Time of day:** at high-energy times (late morning, after school) the hardest work goes first. Late at night it puts important work first, then shorter and lighter tasks. If a quick task (20 min or less) is due soon, it goes first to get you started.
4. **Safety check:** if that order would make anything late, it switches to a strict earliest-deadline-first order.
5. **Breaks:** work is split into 45-minute focus blocks with 10-minute breaks. You can change all of these in Settings.

## Project layout

```
Packages/BrainCore/        Pure Swift logic + 40 unit tests (cd there and run `swift test`)
  NaturalLanguageParser    quick-add parsing
  ProgressLog              plain-English progress logging + matching your words to an assignment
  Tracking                 steps, progress, pace, grades, workload
  Scheduler                check-in timeline
  SyncMerger / Models      data + newest-wins merge
App/Mac/Blob/             Blob: corner panel + blob, voice, Claude / on-device brains, Mac tools
App/Shared/                SwiftUI app shared by Mac and iOS
  Services/                Google sign-in (PKCE), Classroom, Drive sync, Google Calendar/Tasks, Apple Calendar/Reminders sync
  Store/BrainStore         app state, saves to ~/Library/Application Support/ArjunsBrain
  Views/                   Today, Calendar, Assignments, Settings, editors, theme
project.yml                XcodeGen spec (run `xcodegen generate` after adding files)
```
