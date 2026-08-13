---
name: work-on-groupy-codex
description: Work on, debug, extend, or reverse-engineer the Windows Groupy + VS Code + Codex automation stack in this repo. Use when changing PowerShell helpers, Groupy tab/window behavior, Codex title/rename/activity/usage features, startup supervisor behavior, layout/keybind ideas, sidecar windows, activity dots, overlays, or any hacky Windows automation for codex-groupy-vscode-tabs.
---

# Work on Groupy Codex

## Core posture

Treat this repo as a personal, Windows-specific, reverse-engineered automation lab for the user's Codex workflow.

Be ambitious and practical:

- Prefer evidence and small probes over saying “that is impossible.”
- Use Win32, UI Automation, VS Code/Codex extension internals, local Codex files, Node Inspector, Groupy memory, WPF overlays, Scheduled Tasks, and PowerShell when they are the best tool.
- Expect some solutions to be version-specific to this Windows/Groupy/Codex setup.
- Preserve old experiments and evidence unless the user explicitly asks to delete them.
- Make the daily workflow feel magical, but never at the cost of lag, broken hotkeys, or stale visual state.

The vibe is hacky, but the engineering standard is high: isolate layers, test real behavior, add concise diagnostics, and keep a rollback path.

## First reads

Read only the docs relevant to the task:

- For new-machine setup, Groupy settings, startup task, or install repair: read `SETUP.md` and consider the `setup-codex-groupy-vscode-tabs` skill.
- For current architecture overview and daily helper behavior: read `README.md`.
- For Groupy internals, no-dialog rename history, tab-order offsets, and confirmed non-solutions: read `docs/REVERSE_ENGINEERING_LOG.md`.
- For activity dots bugs/audit context: read `docs/ACTIVITY_DOTS_AUDIT_HANDOFF.md`.
- For the working live lifecycle dot architecture: read `docs/ACTIVITY_DOTS_LIVE_LIFECYCLE_HANDOFF.md`.
- For cached all-groups dot performance design: read `docs/ACTIVITY_DOTS_ALL_GROUPS_IMPLEMENTATION_PLAN.md`.
- For future window layout, sidecar, and keybind work: read `docs/CODEX_GROUPY_LAYOUT_KEYBINDS_HANDOFF.md`.

Do not reread every large doc when the task is narrow. Use headings and `rg` to find the relevant section.

## Current system map

Runtime scripts live in `scripts\`.

Daily supervised helpers:

```text
CodexGroupyTabSync.ps1 -WatchAutoTitle
  Reads the selected Codex chat from VS Code UI Automation and writes it to the native VS Code caption so fresh Groupy tabs follow it.

CodexChatRenameHotkey.ps1
  Ctrl+Shift+R rename. Uses the VS Code extension host's live Codex connection when possible, with safe persisted fallback.

GroupyNumberTabs.ps1
  Ctrl+1 through Ctrl+9 exact Groupy tab selection. Reads GroupyCtrl's live ordered HWND array; normal path uses no OCR.

GroupySeparateWindowHotkey.ps1
  Ctrl+Shift+N duplicate workspace + physically separate into a new Groupy group.

GroupyUsageOverlay.ps1
  Active-strip context/weekly usage badge plus global white/yellow/green Codex counts.

GroupyCodexActivityDots.ps1 -AllGroupsCached
  Yellow/green per-tab Codex activity dots across visible Groupy strips using cached rendering.
```

Supervisor/startup:

```text
CodexGroupySupervisor.ps1
Start-CodexGroupyTools.ps1
Stop-CodexGroupyTools.ps1
Install-CodexGroupyEnvironment.ps1
```

Shared bridge:

```text
CodexVsCodeLiveRenameBridge.js
```

The bridge is intentionally version-sensitive. It reaches the VS Code extension host through Node Inspector to use the existing Codex connection owned by VS Code.

## Non-negotiables

- Do not use OCR for normal Groupy tab order, dot placement, or state detection.
- Do not make manual Groupy clicks slower.
- Do not make `Ctrl+1` through `Ctrl+9` slower or less reliable.
- Do not cause VS Code lag while typing, scrolling, or dragging windows.
- Do not do UI Automation, recursive filesystem scans, network/listener discovery, or full session parsing in a visual render loop.
- Do not let diagnostics throw inside timers/render loops.
- Do not enable orange/needs-input paths by default unless explicitly requested.
- Do not promote fragile all-groups or layout experiments into default startup until tested.
- Preserve `archive\`, `docs\`, logs, and experiment evidence unless explicitly told otherwise.
- Keep a clear stop/restart path through the supervisor.

## Working assumptions and known hacks

- Groupy build is currently Stardock Groupy 2.3.1.1. Memory offsets are build-specific.
- Groupy tab order is read from `GroupyCtrl.exe` group records:
  - group record table RVA `0x196F30`;
  - record size `0x7CC0`;
  - strip HWND offset `+0x7BF0`;
  - ordered member HWND array `+0x7040`;
  - tab rectangle array `+0x76E8`;
  - capacity `53`.
- Fresh Groupy tabs follow native VS Code window captions. Manually renamed Groupy tabs become custom and may stop following captions.
- Codex `session_index.jsonl` is append-only. Multiple rows for the same thread are title revisions, not duplicate chats.
- A separate `codex app-server` can read persisted state, but live VS Code status/rename behavior requires the actual extension-owned connection.
- Local rollout files are useful fallback/recovery signals, but live yellow activity should prefer extension-host lifecycle events when available.

## Development workflow

Start with status and evidence:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
Get-Content .\work\CodexGroupySupervisor.log -Tail 80
```

Inspect only the relevant subsystem:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -Inspect
.\scripts\GroupyNumberTabs.ps1 -Inspect
.\scripts\GroupyCodexActivityDots.ps1 -Inspect -AllGroups
.\scripts\GroupyUsageOverlay.ps1 -InspectContext
Get-Content .\work\CodexChatRenameHotkey.log -Tail 80
Get-Content .\work\ActivityDotsRuntime.log -Tail 120
```

When changing helpers:

1. Confirm the current process state.
2. Make the smallest useful patch.
3. Parse-check changed PowerShell files.
4. Restart only affected helpers when possible.
5. Test in real VS Code/Groupy windows.
6. Check logs for errors and slow-update lines.
7. Commit and push if the user expects repo persistence.

Parse-check:

```powershell
$failed = $false
foreach ($file in Get-ChildItem .\scripts -File -Filter *.ps1 | Sort-Object Name) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) > $null
  if ($errors.Count) {
    $failed = $true
    Write-Host "$($file.Name) parse FAILED"
    $errors | Format-List
  } else {
    Write-Host "$($file.Name) parse OK"
  }
}
if ($failed) { exit 1 }
```

## Performance rules

Favor event-driven or cached design:

- Use foreground/window events when possible.
- Cache Groupy strip/member geometry and invalidate on focus, drag end, or signature change.
- Mark dirty and redraw only changed overlays.
- Hide overlays during window move/resize and skip expensive work until move end.
- Keep hotkey polling modest and cheap; current user preference is about 25 ms for hotkey responsiveness where polling is used.
- Keep visual render-loop work tiny. A normal tick should be close to free; slow watchdog logs matter.

Do not put these in timer/render loops:

```text
Get-CimInstance
Get-NetTCPConnection
Invoke-RestMethod
recursive Get-ChildItem
UI Automation tree walks
full session-index reload unless timestamp changed
Groupy all-record scans unless cache invalidated
JSON parsing of large rollout histories
```

## Hotkey philosophy

Hotkeys should feel direct and scoped:

- Existing `Ctrl+number` is for tabs inside the current Groupy group.
- Existing `Ctrl+Shift+R` is chat rename.
- Existing `Ctrl+Shift+N` is duplicate/separate workspace.
- Proposed future `Ctrl+Shift+1/2/3/4` layout hotkeys are acceptable; user said they do not conflict with VS Code.
- Proposed `Ctrl+Shift+Tab` should cycle Groupy/VS Code groups, not individual tabs.
- Proposed sidecar keys: `Ctrl+Shift+=` to add a sidecar Codex chat, `Ctrl+Shift+-` to remove it.

If a hotkey should not affect Chrome/other apps, scope it to Groupy-linked VS Code, temporarily release/pass through, or decline outside target context.

## Layout and sidecar direction

For layout work, use `docs/CODEX_GROUPY_LAYOUT_KEYBINDS_HANDOFF.md`.

Recommended phases:

1. Safe layout/focus only:
   - `Ctrl+Shift+Tab`;
   - `Ctrl+Shift+1/2/3/4`;
   - monitor-local Win32 placement.
2. Sidecar v1:
   - duplicate current workspace;
   - position main + narrow Codex sidecar;
   - track relationship in ignored local state;
   - do not obsess over making it literally one Groupy tab.
3. Activity navigation:
   - focus next yellow/running or green/completed chat.
4. Groupy membership split/merge:
   - `Ctrl+Shift+Enter`, `Ctrl+Shift+Backspace`, `Ctrl+Shift+0`;
   - treat this as the fragile layer and probe carefully.

## Activity dots direction

For activity dots, preserve the user-verified yellow/green behavior:

- yellow appears immediately on live turn start;
- focused completion clears yellow to no dot;
- background completion turns green;
- focusing exact window clears green;
- no dot for unresolved/non-Codex tabs.

Keep orange disabled by default.

Cached all-groups rendering is the preferred current direction, but do not revive the old direct `-AllGroups` path as daily behavior. Watch for periodic lag and `SLOW UPDATE` diagnostics.

## Rename/title direction

Preserve no-dialog title sync:

- Use UI Automation to read the exact selected Codex chat inside the relevant VS Code window.
- Set native VS Code caption for fresh Groupy tabs.
- Do not infer a window's active chat from global Codex storage alone.
- On Codex home/closed, show workspace/project directory only unless the user asks for explicit suffixes.

Preserve rename safety:

- Use live VS Code extension connection when available.
- Deduplicate append-only session-index revisions by thread ID.
- Retain historical title aliases when unambiguous because VS Code/Groupy captions can stay stale after a rename.
- Refuse duplicate-title ambiguity rather than guessing.

## Commit hygiene

Before committing:

```powershell
git status --short
git diff
```

Do not commit ignored runtime state from `work\`, `backups\`, screenshots, or generated native binaries. If a new local runtime file appears, add a narrow `.gitignore` rule rather than committing secrets or volatile state.

Use clear commit messages and push when the user asks for persistent repo updates.

## If blocked

Do not stop at “not possible” until you have identified the actual boundary:

- What window/HWND/state can be observed?
- What command/message/file/event changes when the user performs the action manually?
- Is there a live app/server/pipe/Inspector/registered message involved?
- Can the behavior be reproduced with a tiny probe?
- Can a safe approximation deliver the workflow without the perfect internal API?

Report exact evidence, current failure mode, and the next plausible probe.
