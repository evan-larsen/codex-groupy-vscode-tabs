# Full project and activity-dots audit handoff

## Read this first

This repository is a personal Windows 11 workflow for VS Code + the Codex VS Code extension + Stardock Groupy 2.
The user works with many VS Code windows grouped into Groupy tabs, often across monitors. They value fast,
keyboard-driven behavior and are very sensitive to visual flash, lag, stale state, and any effect on VS Code
responsiveness.

The core workflow works well. The **only active problem in this handoff is `GroupyCodexActivityDots.ps1`**:
yellow/green per-tab Codex activity dots are currently unreliable and the helper has been stopped for safety.
Do not delete it or abandon the feature. Audit and repair it.

Important: do not indiscriminately clean the repo. The user explicitly asked to retain old experiments because they
are useful reverse-engineering evidence.

## Current safety state at handoff

- `GroupyCodexActivityDots.ps1` was explicitly stopped at handoff time because it was showing stale/missing dots and
  VS Code became nearly unresponsive while it ran.
- `Start-CodexGroupyTools.ps1` still lists activity dots because the user asked not to remove the feature. Do not
  casually run the daily launcher until the activity helper is fixed, or it will start the helper again.
- The other four daily helpers remain running and were intentionally not stopped:

  - `CodexGroupyTabSync.ps1 -WatchAutoTitle`
  - `GroupyNumberTabs.ps1`
  - `GroupySeparateWindowHotkey.ps1`
  - `GroupyUsageOverlay.ps1`

Use this to confirm process state:

```powershell
cd C:\Users\evanl\Documents\groupy-vscode-codex-tabs
.\scripts\Start-CodexGroupyTools.ps1 -Status
```

Use this to stop every managed helper if necessary:

```powershell
.\scripts\Stop-CodexGroupyTools.ps1
```

## Machine and fixed-build assumptions

- OS: Windows 11.
- Groupy: Groupy 2.3.1 on this machine. The direct Groupy memory offsets below are reverse-engineered for this exact
  build, not a portable Groupy API.
- VS Code executable: `Code.exe`.
- Codex extension installation is version-sensitive and changes often. Current/recent installed paths observed:

  - `C:\Users\evanl\.vscode\extensions\openai.chatgpt-26.803.41515-win32-x64`
  - a newer installed-but-not-necessarily-reloaded extension was also observed during development.

- Local Codex data:

  - session index: `C:\Users\evanl\.codex\session_index.jsonl`
  - rollout logs: `C:\Users\evanl\.codex\sessions\...\rollout-...<thread-id>.jsonl`

## What the finished workflow is supposed to provide

1. Fresh Groupy tabs reflect the currently selected Codex chat title without the Groupy Rename Tab dialog.
2. Codex home/new-chat labels as `workspace - Codex home`; Codex view closed labels as `workspace - Codex closed`.
3. `Ctrl+1` through `Ctrl+9` switch to exact Groupy tab positions, honoring manual reorder.
4. `Ctrl+N` duplicates the current VS Code workspace into the current Groupy group.
5. `Ctrl+Shift+N` duplicates the workspace and physically detaches it into its own Groupy group.
6. A right-side Groupy-strip text overlay shows context and weekly usage, e.g.
   `Context 53%  |  Weekly 85% · 6d`.
7. Fast `Ctrl+Shift+R` Codex chat rename through the live extension connection for normal local threads.
8. The unfinished feature: tiny per-Groupy-tab activity dots:

   - yellow, gently pulsing = a Codex turn is working;
   - green = an unread completed turn; focusing that exact VS Code window clears green;
   - orange (future/optional) = Codex asks for user input/approval.

## Files and their roles

| File | Purpose / status |
| --- | --- |
| `Start-CodexGroupyTools.ps1` | Daily launcher. Currently lists all standard helpers including the activity-dot script. |
| `Stop-CodexGroupyTools.ps1` | Stops known managed PowerShell helpers. |
| `CodexGroupyTabSync.ps1` | **Working.** `-WatchAutoTitle` uses the no-dialog caption-following Groupy behavior. |
| `CodexGroupyTabSync-legacy-popup-free.ps1` | Retained older route; do not treat as daily implementation. |
| `GroupyNumberTabs.ps1` | **Working.** Global Ctrl+1–Ctrl+9 exact tab selection. |
| `GroupySeparateWindowHotkey.ps1` | **Working.** Ctrl+Shift+N duplicate + physical Groupy tab detachment. |
| `GroupyWindowShortcuts.ps1` | Earlier experiments/prototype used by the separate-group work. |
| `GroupyUsageOverlay.ps1` | **Working.** Active-strip text overlay for context/weekly usage. |
| `Get-CodexUsage.ps1` | Reads local Codex weekly usage. |
| `CodexChatRenameHotkey.ps1` | Working for ordinary local Codex threads; special anomalous thread is deliberately declined. |
| `CodexVsCodeLiveRenameBridge.js` | Node Inspector bridge used by rename and previously by optional activity prompt detection. Version-sensitive. |
| `GroupyCodexActivityDots.ps1` | **Current audit target.** Dots functionality must be fixed. |
| `work\ActivityDotsRuntime.log` | Runtime diagnostic log recently added to the activity script. Read it before assuming behavior. |
| `README.md` | User-facing usage and architecture documentation. |
| `REVERSE_ENGINEERING_LOG.md` | Detailed Groupy/Codex experiments and evidence. |
| `GroupyLinkTrace.cpp`, `Start-GroupyDetachTrace.ps1` | Detach research evidence. |
| `GroupyMessageTrace*`, `GroupyNoFlashHook*` | Retained native Groupy rename/no-flash experiments. |
| `Inspect-CodexAppServerPipes.ps1`, `Test-CodexLivePipeRename.ps1` | Rename/app-server investigation helpers. |

## Working Groupy reverse engineering

The key discovery was that Groupy stores live per-group tab state in `GroupyCtrl.exe` memory. For this Groupy 2.3.1
build:

| Item | Value |
| --- | --- |
| Group record table RVA | `0x196F30` |
| Record count | `0x7D0` |
| Record size | `0x7CC0` |
| Groupy strip HWND offset | `+0x7BF0` |
| Ordered member HWND array | `+0x7040` |
| Tab rectangle array | `+0x76E8` |
| Ordered tab capacity | `53` |

The member VS Code windows have a `GP_LINK` window property pointing to the Groupy strip HWND. `GroupyNumberTabs.ps1`
uses the ordered HWND list and focuses the desired window. This is exact, dynamic, and does not use OCR or cached order.

`GroupyCodexActivityDots.ps1` reads the same tab HWNDs and rectangle array to position dots at the right side of each
Groupy tab. It currently uses WPF transparent overlays, which are the suspected rendering/interference area.

## Title synchronization: solved, do not regress

Groupy's normal Rename Tab hotkey creates a native dialog and can flash even when submitted quickly. Many attempted
ways to remove it failed (direct `SetWindowText`, Groupy registered messages, memory edits, hooks). The successful
route is different:

- Fresh Groupy tabs that have **never been manually renamed** follow their application window caption.
- `CodexGroupyTabSync.ps1 -WatchAutoTitle` gets the selected Codex chat title via Windows UI Automation and sets the
  native VS Code window caption.
- Groupy updates the tab label immediately, with no Rename Tab dialog.
- Manually renamed Groupy tabs are marked custom and no longer follow caption changes. The practical migration is to
  close/reopen those VS Code windows as fresh Groupy tabs and never use Groupy's Rename Tab command on them.

This feature has been confirmed by the user as very clean and fast. Preserve it.

## Usage/context overlay: working reference implementation

`GroupyUsageOverlay.ps1` is important as a reference because it has a stable transparent WPF overlay over the active
Groupy strip. It:

- shows normal weight Segoe UI text in `#dcdcdc`;
- is click-through/no-activate;
- hides during native move/resize events;
- only draws over the active Groupy/VS Code strip;
- reads local rollout `token_count` records and the local usage helper;
- updates context on focus changes and a short interval.

The activity implementation should compare its window ownership/z-order/hit-test/render lifecycle carefully against
this known-working overlay. Do not assume WPF itself is universally broken.

## Codex rename: status and caveat

`thread/name/set` through a separate `codex app-server` process updates persisted storage but does not reliably update
the already-open VS Code UI. The working rename hotkey finds the actual VS Code extension-host Node Inspector endpoint,
locates the loaded `CodexWebviewProvider`/`CodexMcpConnection`, and invokes the rename through that existing connection.

Known anomaly: thread `019febf1-11ba-7ba0-8228-cd3e2a220648` is this task, titled live as
`Automate Groupy Codex tabs`. Its local session index has conflicting/newer `Automate Groupy Codex tabs 2` state.
The rename script intentionally refuses to guess. This same anomaly means dots cannot resolve this tab by title either.
This is expected for that one task, not proof that dots are generally broken.

## Activity-dots implementation history

### Initial version: worked well visually

The first basic implementation did the following:

- Local Codex rollout logs contain exact lifecycle records:

  ```json
  {"type":"event_msg","payload":{"type":"task_started", ...}}
  {"type":"event_msg","payload":{"type":"task_complete", ...}}
  ```

- Latest lifecycle event means yellow `working` or green `finished`.
- A single click-through transparent WPF window was placed over the foreground Groupy strip.
- A yellow pulse was later added. User initially described the activity dots as “super sick” and very useful.

### Requested enhancements

The user then requested:

1. yellow should pulse;
2. green should be an unread-completion indicator and clear after focusing its VS Code window;
3. orange for a genuine request for approval/input;
4. dots on all visible Groupy/VS Code groups across monitors, but never floating over an unrelated foreground app.

### Orange / `needs you` research

The live VS Code extension receives structured server requests such as:

- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`
- `serverRequest/resolved`

`CodexVsCodeLiveRenameBridge.js` was extended with a `watch-activity` operation that attaches through Node Inspector
and observes the actual extension connection. This was technically successful in a direct test, but it is private,
version-sensitive, and not needed for basic yellow/green lifecycle dots. The current script’s normal path still has
the bridge code present. Treat it as opt-in/experimental; do not make it the first thing to debug.

### Multi-monitor/all-groups experiment: failed

`-AllGroups` created one WPF overlay per Groupy strip and made each overlay an owned window of a Groupy strip so it
would appear over background VS Code windows but remain behind other foreground apps. It also added native
`WM_NCHITTEST -> HTTRANSPARENT` because WPF `IsHitTestVisible = false` is not sufficient to make an entire native
window click-through.

Observed user behavior:

- manual Groupy tab clicks became delayed by seconds;
- Ctrl+number switches queued or became slow;
- stale dots appeared on background groups;
- Groupy activation flickered.

The user asked to roll this back. The default code path is intended to use only the active strip. Retain `-AllGroups`
for research but do not treat it as working.

### Performance bugs found and addressed

Several real regular-path issues were discovered while trying to fix dots:

1. `Get-Content -Tail 4000` + `ConvertFrom-Json` on a rollout on every write can be very slow for long chats.
2. Old `Update-CodexSessionMap` recursively searched the full `.codex\sessions` tree once for every title in
   `session_index.jsonl`. On this machine a broad scan could exceed a minute.
3. A direct `rg --files ... -g "*<thread-id>.jsonl"` lookup was measured at about 87 ms, versus recursive PowerShell
   enumeration being much slower.
4. The script now contains `ActivityLogProbeV1`, a C# byte probe that attempts to locate only the latest lifecycle
   marker and thereafter inspect appended bytes. This needs an independent audit; it was introduced during a rapid
   debugging sequence and was not fully user-verified.
5. The probe initially had an escaping bug and searched for literal backslash-quote bytes. It was corrected from
   `\\\"type` to C# string `\"type`, but again needs review and tests.

### Critical rendering bug found in the last session

The helper was instrumented with `work\ActivityDotsRuntime.log`. This exposed the following repeated fatal callback
error:

```text
UPDATE ERROR: The variable '$owner' cannot be retrieved because it has not been set.
```

Cause: `Update-ActivityOverlay` had renamed `$owner` to `$visibleTab`, but newly added diagnostics still referenced
`$owner`. The error happened every timer tick before rendering, explaining one-shot/stale/blank behavior. The line was
subsequently changed to `$visibleTab` and the log then showed a clean state entry such as:

```text
[16:25:27.081] strip=0x7094A; visibleTab=0x60058; dots=3150190|finished|220,0,440,31
```

However, the user immediately reported that a new active chat still did not show yellow, while an old unfocused window
retained yellow. Therefore do **not** assume that fixing `$owner` completed the problem. Reproduce and audit end-to-end.

### Recent raw diagnostic evidence

The following command was added and works:

```powershell
.\scripts\GroupyCodexActivityDots.ps1 -Inspect -AllGroups
```

It prints direct Groupy strip/member HWNDs, captions, matching thread IDs, rollout path, and raw lifecycle state without
creating WPF overlays. A representative recent output:

| Strip | Caption | Thread | Raw lifecycle |
| --- | --- | --- | --- |
| `0x7094A` | `Automate Groupy Codex tabs` | unresolved (known anomalous thread) | none |
| `0x7094A` | `Check OTA Mandatory 2` | `019fecdd-e0b4-7d70-9f9f-218ace327e47` | finished |
| `0x5C12AC` | `Fix preview release key error` | `019fed96-8252-7fe3-8738-f3326c0a43ab` | working |

The last chat’s raw rollout genuinely showed a rapid sequence of task complete then a new task started. This explains
some apparently contradictory “it finished but yellow remains” observations, but not the user’s broader complaint that
new current chats fail to display yellow and old background dots remain.

## Exact current user complaint to solve

After the latest activity-dot changes, the user reports all of the following:

- A newly started Codex chat in the current VS Code window does not get a yellow dot.
- A yellow dot stays in an old/unfocused VS Code window and does not update when its Codex task changes state.
- Yellow sometimes appears once but does not pulse.
- When the active tab completes, green/clear behavior is inconsistent.
- Earlier all-groups attempts made manual Groupy clicks and Ctrl+number switching very slow.
- At least once VS Code almost froze/stopped responding while activity dots were running.

These issues are real from the user’s perspective even when a snapshot of raw logs looks correct. Do not argue from a
single `-Inspect` result; reproduce focus switching and observe updates over time.

## Activity script structure to audit

The relevant code is all in `GroupyCodexActivityDots.ps1`:

- `ActivityDotsNativeV1` C#:
  - Groupy memory reads;
  - tab rectangles;
  - window properties/text;
  - move/resize events;
  - `EnumWindows` group discovery;
  - WPF ownership/window style helpers.
- `ActivityBridgeProcessV1` C#: optional Node bridge child process.
- `ActivityLogProbeV1` C#: new byte-level rollout state probe.
- `Update-CodexSessionMap`: title → unique local thread ID mapping.
- `Resolve-CodexSessionLogPath`: lazy rollout lookup using `rg`.
- `Resolve-CodexChatForWindow`: caption/title → cached thread/log mapping.
- `Get-DisplayActivityState`: yellow while working; green only if a completed turn is unread; clears when foreground
  window equals the tab HWND.
- `New-ActivityOverlay` / `Update-ActivityOverlay`: WPF canvas and dots.
- `Update-ActivityDots`: current foreground strip by default; all groups only with `-AllGroups`.

Potential audit concerns:

1. The active-only overlay dictionary is keyed by strip. When moving between Groupy groups, verify old overlays are
   hidden/closed synchronously and no stale topmost WPF window survives.
2. Verify `GP_LINK` stability and whether a Groupy strip can be invalid/recycled after focus changes.
3. Verify the WPF overlay window is truly hit-test transparent and cannot block Groupy focus/click routing.
4. Audit `Get-DisplayActivityState`: initial state, task restart after completion, focus transition, and unseen-state
   persistence all need deterministic tests.
5. Do not update UI or access heavyweight filesystem/Inspector APIs on the WPF Dispatcher timer. The current code was
   rapidly changed and may still violate this in subtle ways.
6. Ensure a timer exception cannot silently leave a stale overlay visible. Runtime diagnostics should report each
   exception without masking it.
7. Separate three independently testable layers: (a) Groupy tab discovery/rectangles, (b) Codex thread/lifecycle
   resolution, and (c) overlay rendering/update/disposal.

## Suggested audit plan

1. **Start from a safe baseline.** Keep the activity helper stopped. Confirm all other helper status remains normal.
2. **Audit source statically.** Do not make a large rewrite first. Trace every `return`, exception, WPF ownership call,
   and state cache transition in `GroupyCodexActivityDots.ps1`.
3. **Create deterministic inspect modes/tests** rather than relying on live WPF visuals:

   - enumerate all Groupy strips and member HWNDs;
   - show native captions and resolved thread IDs;
   - show raw lifecycle marker/offset/file timestamp;
   - show computed display state (`working`, `unread finished`, or empty);
   - show whether an overlay exists/is visible for each strip.

4. **Prove regular yellow/green first** with one active Groupy group, no all-groups, no Inspector bridge, and ideally no
   WPF pulse animation. The current chat should render yellow within one short tick of a known `task_started`; a known
   task complete in a background tab should render green; focusing it should clear only that dot.
5. **Only then add pulse** and verify that moving/repositioning does not recreate the Ellipse or restart its animation.
6. **Only then revisit all-groups/background overlays.** A safer architecture may be one passive overlay window rather
   than per-strip owned WPF windows, or a non-WPF native layered window. Do not regress Groupy switching responsiveness.
7. Keep `-AllGroups` off by default until manual clicks and Ctrl+number switching are verified clean.
8. Keep the optional Node Inspector prompt observer off until basic dots are stable and VS Code responsiveness is
   proven.

## Useful commands for the auditor

```powershell
cd C:\Users\evanl\Documents\groupy-vscode-codex-tabs

# Raw state only; no overlay.
.\scripts\GroupyCodexActivityDots.ps1 -Inspect -AllGroups

# Tail current activity runtime diagnostics.
Get-Content .\work\ActivityDotsRuntime.log -Tail 80

# Confirm normal helpers without starting missing ones.
.\scripts\Start-CodexGroupyTools.ps1 -Status

# Run only the activity helper after you have a safe repair.
.\scripts\GroupyCodexActivityDots.ps1

# Stop it immediately if Groupy/VS Code becomes laggy.
Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -match 'GroupyCodexActivityDots\.ps1' -and $_.ProcessId -ne $PID
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

## User expectations and non-negotiables

- No OCR for Groupy tab ordering or dot placement.
- Keep Groupy/VS Code interaction extremely responsive. A status indicator must never make clicking or Ctrl+number
  switching feel delayed.
- No visible rename dialogs for normal tab title synchronization.
- Preserve all old experiments/files unless there is explicit user permission to clean them up.
- Be honest about evidence. If raw data says a task restarted after it completed, explain the timestamps; do not use
  that to dismiss a reproducible stale-render issue.
- The user wants to keep investigating and does **not** want activity dots removed from the project. The helper was
  stopped only to avoid misleading/freeze-inducing runtime behavior while it is audited.
