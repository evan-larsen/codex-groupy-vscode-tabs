# Activity Dots All-Groups Implementation Plan

Timestamp: 2026-08-11

Workspace:

```text
C:\Users\evanl\Documents\groupy-vscode-codex-tabs
```

Related context:

- `ACTIVITY_DOTS_AUDIT_HANDOFF.md`
- `ACTIVITY_DOTS_LIVE_LIFECYCLE_HANDOFF.md`

## Objective

Extend Codex activity dots from the active Groupy strip to every visible Groupy / VS Code strip, without reintroducing drag lag, tab-switch lag, or VS Code freezes.

Desired behavior:

- yellow dot on any visible Groupy tab whose Codex thread is actively running
- green dot on any visible Groupy tab whose Codex thread completed while unread
- focusing the exact VS Code window clears green
- no dot for unresolved/non-Codex tabs
- active-strip behavior must remain as fast as it is now
- window dragging must remain effectively zero-lag

## Non-Negotiables

- no OCR
- no UI Automation in the visual render loop
- no rollout/session-file scanning in the visual render loop
- no Groupy memory reads while any VS Code/Groupy window is being moved/resized
- no WPF overlay placement while any VS Code/Groupy window is being moved/resized
- no all-groups default until the cached implementation is tested
- preserve old experiment files
- keep orange/needs-input disabled by default
- diagnostics must never break or block rendering

## Current Working Baseline

The active-strip implementation works well after the live lifecycle changes.

Current architecture:

```text
VS Code Codex extension host
  -> Node inspector websocket
  -> CodexVsCodeLiveRenameBridge.js trace-activity
  -> lifecycle-only JSON lines
  -> GroupyCodexActivityDots.ps1 liveActivityByThread
  -> active Groupy strip overlay
```

Important properties already achieved:

- live `turn/started` drives instant yellow
- live `turn/completed` drives immediate clear/green
- focused completion clears to no dot
- background completion turns green
- focus clears green
- stale rollout `working` is suppressed when live bridge is ready
- drag quiet mode hides overlays and returns before expensive work

## Why The Old All-Groups Mode Lagged

The old all-groups approach was too poll-heavy:

- discover all Groupy strips repeatedly
- read Groupy memory repeatedly
- resolve captions/titles repeatedly
- update WPF overlay positions repeatedly
- sometimes touch session/log state repeatedly

This makes small periodic costs line up with Groupy drag/move/focus work. The fix is not simply making the timer slower. The fix is to separate discovery, state, and rendering.

## Proposed Architecture

Use retained state and dirty rendering.

Core state:

```text
liveActivityByThread:
  threadId -> working / finished / stopped

windowBindings:
  hwnd -> {
    strip,
    caption,
    titleKey,
    threadId,
    lastResolvedAt,
    unresolvedRetryAt
  }

stripCache:
  strip -> {
    tabs,
    overlay,
    lastGeometrySignature,
    lastRenderSignature,
    dirty,
    lastDiscoveredAt
  }

threadToWindows:
  threadId -> hwnd[]
```

The visual path should be:

```text
if any move/resize active:
  hide all overlays once
  return

process live bridge events
mark affected strips dirty
redraw only dirty visible strips
```

## Phased Implementation

### Phase 1: Passive Caches, No Visual Change

Add the new caches while keeping the visible behavior active-strip only.

Tasks:

- add `windowBindings`
- add `stripCache`
- add `threadToWindows`
- add helper to resolve a tab/window once and cache the result
- add helper to mark a strip dirty
- add diagnostics for cache counts and dirty strips

Success criteria:

- no user-visible behavior change
- no new slow-update logs during normal idle
- drag remains smooth
- active-strip dots still work

### Phase 2: Cached Groupy Strip Discovery

Replace repeated all-groups discovery with a cached discovery loop.

Rules:

- discover visible strips slowly, for example every 2-5 seconds
- immediately skip discovery during move/resize
- validate cached strip records before use
- do not touch per-tab title/session state unless the strip is dirty or a tab is unresolved and its retry time arrived

Success criteria:

- cache sees all visible VS Code Groupy strips
- active-strip render still unchanged
- no repeated expensive Groupy reads while idle

### Phase 3: Dirty-Only Rendering

Introduce a new switch:

```powershell
-AllGroupsCached
```

This switch renders all visible strips using retained overlays.

Dirty triggers:

- live lifecycle event for a thread mapped to one or more windows
- foreground/focus change
- Groupy strip membership or tab rectangle signature changed
- new/unresolved window title changed
- move/resize ended
- helper startup

Do not redraw a strip if its render signature is unchanged.

Success criteria:

- yellow appears on active strip
- yellow appears on background tab in same strip
- yellow appears on visible tab in another Groupy strip/window
- green appears for unread background completion
- focusing exact window clears green
- no dots for unresolved tabs

### Phase 4: Drag/Move Hardening

Keep the proven quiet mode:

```text
any VS Code move/resize active:
  Hide-AllActivityOverlays
  skip all strip discovery
  skip all tab reads
  skip all title/session/log resolution
  skip all WPF placement
```

On move end:

- mark all known strips dirty
- redraw once on next timer tick

Success criteria:

- dragging a VS Code/Groupy window feels identical with helper stopped vs running
- no `SLOW UPDATE` logs during drag
- overlays reappear after drag ends

### Phase 5: Promote Or Keep Switch

Only after repeated testing:

- either make cached all-groups the default
- or keep it as an explicit startup argument in `Start-CodexGroupyTools.ps1`

Do not reuse the old `-AllGroups` path as default.

## Performance Rules

Render loop budget:

```text
normal tick: ideally < 10ms
dirty redraw: ideally < 50ms
slow watchdog: log >= 750ms
```

Render loop must not do:

- `Get-CimInstance`
- `Get-NetTCPConnection`
- `Invoke-RestMethod`
- recursive `Get-ChildItem`
- UI Automation
- full session-index reload unless the index timestamp changed
- Groupy all-record scan unless cache invalidated

Allowed in render loop:

- drain already-running bridge queues
- check `IsAnyMoveSizeActive`
- inspect dirty cached strips
- call `GetWindowRect` only for dirty visible strips and only when not dragging
- update WPF visuals only when render signature changed

## Diagnostics To Add

Keep diagnostics concise and change-only.

Useful lines:

```text
allgroups-cache strips=2 windows=6 unresolved=1 dirty=1
allgroups-render strip=0x... tabs=3 dots=2 elapsedMs=7
allgroups-dirty reason=live-thread thread=... strips=0x...
allgroups-skip moving=true
SLOW UPDATE elapsedMs=...
```

Diagnostics must be wrapped in best-effort try/catch.

## Test Matrix

Basic:

- active chat starts -> yellow immediately
- active chat finishes focused -> clears immediately
- background tab in same strip starts -> yellow
- background tab in same strip finishes -> green
- focus background completed tab -> green clears

Multi-strip:

- chat in another Groupy strip/window starts -> yellow visible there
- chat in another Groupy strip/window finishes while not focused -> green
- focus exact completed window -> green clears
- switching to a different tab in the same strip does not clear another tab's green

Unresolved/new windows:

- new VS Code window with Codex home -> no dot
- new Codex chat before title exists -> no wrong dot
- after title sync catches up -> dot binds to correct thread
- duplicate titles -> no guessing unless uniquely resolvable

Manual stop:

- start a long task
- stop it manually
- yellow clears
- no green unless it was a real completion

Performance:

- drag a VS Code Groupy window while dots exist
- drag a VS Code Groupy window while multiple dots exist
- Ctrl+1 through Ctrl+9 repeatedly while dots exist
- Groupy manual tab clicks while dots exist
- run two chats concurrently in separate strips
- check for `SLOW UPDATE` logs after each test

## Rollback Plan

If all-groups cached mode causes lag or bad dots:

1. Stop activity dots:

```powershell
$activity = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -match '\-File\s+.*GroupyCodexActivityDots\.ps1' }
foreach ($p in $activity) { Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue }
```

2. Restart without all-groups cached:

```powershell
.\Start-CodexGroupyTools.ps1
```

3. Keep active-strip mode as the known-good fallback.

Do not delete old experiment files or handoff docs.

## Current Recommendation

Implement `-AllGroupsCached` first. Do not change the default startup path until it passes the full test matrix. The current active-strip path is good and should remain the fallback while the ambitious version is tested.

## Implementation Status - 2026-08-11

Implemented first cached all-groups pass in `GroupyCodexActivityDots.ps1`.

Current behavior:

- `Start-CodexGroupyTools.ps1 -AllGroupsCachedActivityDots` starts activity dots with `-AllGroupsCached`.
- Default `Start-CodexGroupyTools.ps1` still uses known-good active-strip mode.
- Cached all-groups mode owns overlays per Groupy strip instead of making them global topmost windows.
- Strip discovery is cached and no longer runs on every visual tick.
- Render work is dirty-only:
  - helper startup
  - new overlay
  - foreground/focus change
  - live lifecycle transition
  - short retry window for a newly working thread that is not mapped to a visible strip yet
- The old 15-second full-strip periodic refresh was removed from cached all-groups mode.
- Repeated identical live lifecycle state updates are now ignored instead of dirtying/redrawing every strip.
- `threadId -> strip` mapping is maintained as strips render, so later lifecycle updates can redraw only affected strips.
- Per-strip diagnostics are now tracked per overlay, not one global signature.
- Bridge discovery now logs concise evidence such as `bridge-discovery hosts=6;listeners=0`.
- Bridge stderr lines are written to diagnostics as `# bridge-error: ...`.

Evidence from the first local restart:

```text
[09:37:41.502] bridge-discovery hosts=6;listeners=0
[09:37:42.085] allgroups-cache strips=2 overlays=0
[09:37:42.737] SLOW STAGES elapsedMs=2449 session-map=271;bridges=946;strips=572;render=655
[09:37:42.742] Activity helper started.
[09:37:43.108] allgroups-cache strips=2 overlays=2
```

After startup, idle stayed quiet except for the 15-second heartbeat. That is the important improvement over the earlier repeated multi-second `SLOW UPDATE` loop.

Current caveat:

- On this run, VS Code had extension-host NodeService processes, but none exposed a listening inspector port, so no live activity bridge process was attached:

```text
bridge-discovery hosts=6;listeners=0
```

That means the cached render loop is running and calm, but live yellow/green lifecycle testing requires the VS Code Codex extension-host inspector to be available again. Previously, reloading the VS Code extension host made that path work.

Next test:

1. Reload the VS Code extension host if needed so the inspector listener appears.
2. Confirm a `node.exe CodexVsCodeLiveRenameBridge.js ... trace-activity` process is running.
3. Run the multi-strip test matrix:
   - active strip start/finish
   - background tab same strip start/finish
   - other Groupy strip/window start/finish
   - focus exact completed tab clears green
   - manual stop clears yellow without green
4. Watch `work\ActivityDotsRuntime.log` for repeated `SLOW UPDATE` lines. A cold-start slow line is acceptable; repeated idle slow lines are not.

## Follow-up Fixes - 2026-08-11

Several issues found during first live all-groups testing:

1. A PowerShell runtime bug caused update errors every 350ms:

```text
UPDATE ERROR (all overlays hidden): The term 'if' is not recognized ...
```

Cause: `return if (...)` in `Get-LiveActivityStrips`. Fixed by using normal PowerShell `if (...) { return ... }`.

2. Cached all-groups produced no dots when VS Code exposed no Node inspector listeners:

```text
bridge-discovery hosts=6;listeners=0
```

Fix: cached all-groups now falls back to rollout/session-file lifecycle state when the live bridge is unavailable.

3. Direct .NET `FileSystemWatcher` callbacks likely caused silent helper exits. There was no `Activity helper stopping.` breadcrumb.

Fix: replaced direct callback mutation with PowerShell event queue registration. The dispatcher tick drains queued file events safely.

4. Yellow dot pulse animation was too expensive across multiple strips.

Evidence before:

```text
CpuSecondsDelta over 10s: ~1.969
```

Fix: `-AllGroupsCached` uses static yellow dots. Active-strip mode can still pulse.

Evidence after static yellow:

```text
CpuSecondsDelta over 10s: ~0.703
```

5. The all-groups dispatcher cadence was still more frequent than needed.

Fix: `-AllGroupsCached` now uses a 1000ms dispatcher timer; active-strip mode remains 350ms.

Evidence after 1000ms cadence:

```text
CpuSecondsDelta over 12s: ~0.109
```

6. Drag quiet mode hid overlays during move but did not explicitly mark strips dirty after move-end.

Fix: added move transition state:

```text
move-start; overlays hidden
move-end; overlays dirty
```

Current all-groups status:

- Background all-groups process can remain running.
- File fallback successfully showed yellow and green without live bridge.
- Startup still has one cold slow line because bridge discovery + first strip scan/render are synchronous.
- Idle should be essentially quiet except for heartbeat and actual session/file/focus changes.

## Periodic Lag Audit - 2026-08-11

User observed a rhythmic VS Code hitch while typing/scrolling. CPU sampling across helpers showed the dots helper was not the primary cause after the static-dot/timer fixes.

Findings:

- `CodexGroupyTabSync.ps1 -WatchAutoTitle` originally polled every 100ms and repeatedly walked VS Code UI Automation trees.
- After first tuning, the remaining hitch cadence matched its 2s UIA loop.
- `GroupyUsageOverlay.ps1` also had a 125ms placement timer.
- `GroupyNumberTabs.ps1` and `GroupySeparateWindowHotkey.ps1` used 15ms message-poll sleeps.

Fixes applied:

- `CodexGroupyTabSync.ps1`
  - default poll interval moved to 2000ms
  - avoids workspace tree scan when a real chat title is already found
  - added fast UIA path for Codex header buttons
  - added adaptive cache/backoff so stable hwnd/title pairs skip expensive UIA scans for several seconds
- `GroupyUsageOverlay.ps1`
  - position timer moved to 1000ms
  - context timer moved to 8s
  - cache warm timer moved to 30s
  - native process-name lookup cached
- `GroupyNumberTabs.ps1`
  - hotkey poll set to 25ms per user preference
- `GroupySeparateWindowHotkey.ps1`
  - hotkey poll set to 25ms per user preference
- `GroupyCodexActivityDots.ps1`
  - WPF continuous opacity animation removed
  - replaced with cheap manual heartbeat opacity toggle every 900ms

Latest sample after these changes:

```text
GroupyNumberTabs.ps1                 0.266 CPU sec / 25s
GroupyCodexActivityDots.ps1          0.266 CPU sec / 25s
GroupySeparateWindowHotkey.ps1       0.250 CPU sec / 25s
CodexGroupyTabSync.ps1               0.094 CPU sec / 25s
GroupyUsageOverlay.ps1               0.062 CPU sec / 25s
```

Important pulse evidence:

```text
WPF continuous pulse: 5.609 CPU sec / 25s
Manual heartbeat pulse: 0.266 CPU sec / 25s
```

So yellow dots now animate again, but with a lightweight heartbeat instead of WPF's continuous animation clock.
