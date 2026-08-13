# Codex + Groupy layout/keybind expansion handoff

This is a full context dump for continuing the “Codex window manager / Groupy cockpit” idea in another chat.

The desired mindset is intentionally hacky and ambitious:

> Do not prematurely say “Windows/Groupy/VS Code cannot do that.”  
> Treat this as a reverse-engineering / automation problem. Use Win32, UI Automation, Groupy behavior, VS Code CLI/commands, logs, probes, and incremental experiments until the actual boundary is known.

This repo already has a working foundation:

- per-Groupy-tab Codex activity dots;
- Groupy tab names synced from Codex chat titles;
- `Ctrl+1` through `Ctrl+9` for exact Groupy tab navigation inside VS Code;
- `Ctrl+Shift+R` for Codex chat rename;
- `Ctrl+Shift+N` for duplicated/separated VS Code windows;
- a supervisor that keeps helpers alive at logon.

The new project is to add a fast, fluid keyboard-driven layout layer for Codex/VS Code/Groupy windows.

## Current user workflow / why this matters

The user works with many Codex chats in VS Code windows grouped by Stardock Groupy. They often want:

- one focused Codex/VS Code workspace;
- two chats side-by-side while comparing or running a quick side task;
- sometimes three columns;
- maybe four columns, but less important;
- a temporary “sidecar” Codex chat attached to the current repo/workspace;
- quick cycling between visible Groupy groups/windows;
- quick collapse back into a main focus state.

The current `Ctrl+number` workflow is good for switching tabs within one Groupy group, but it does not solve spatial work:

- “show this chat next to that chat”;
- “split this current tab out into a visible column”;
- “bring this side chat back home”;
- “layout the current monitor as 2/3 columns”;
- “focus the next active/finished Codex chat.”

The goal is not a general-purpose Windows tiling manager. The goal is a Codex-aware workspace composer.

## Existing relevant scripts

Runtime scripts are in `scripts\`.

Known relevant files:

```text
scripts\CodexGroupySupervisor.ps1
scripts\Start-CodexGroupyTools.ps1
scripts\Stop-CodexGroupyTools.ps1
scripts\CodexGroupyTabSync.ps1
scripts\CodexChatRenameHotkey.ps1
scripts\GroupyNumberTabs.ps1
scripts\GroupySeparateWindowHotkey.ps1
scripts\GroupyWindowShortcuts.ps1
scripts\GroupyUsageOverlay.ps1
scripts\GroupyCodexActivityDots.ps1
scripts\Get-CodexUsage.ps1
scripts\CodexVsCodeLiveRenameBridge.js
```

`GroupyWindowShortcuts.ps1` exists and may be the natural place to expand window/layout shortcuts, or a new helper can be created if cleaner.

The supervisor should own any new daily helper once stable.

## Important design principle

Keep three concepts separate:

```text
Focus/navigation
  Which Groupy group / VS Code window is active?

Layout
  Where are visible groups/windows positioned on the current monitor?

Membership
  Which VS Code/Codex tab belongs to which Groupy group?
```

Window layout and focus are much safer than changing Groupy membership.

Recommended implementation ordering:

1. Build pure window placement/focus first.
2. Add sidecar mode.
3. Only then experiment with actual split/merge of Groupy tabs/groups.

## Research/context from Windows ecosystem

Patterns worth borrowing:

- Windows Snap uses `Win+Arrow` for basic halves/quadrants and `Win+Shift+Arrow` for moving windows across monitors.
- PowerToys FancyZones uses numbered layout shortcuts and keyboard movement between zones.
- FancyZones also has the concept of cycling windows within a zone.
- Tiling managers like GlazeWM/i3/Komorebi use a small grammar:
  - modifier + arrows = move focus;
  - modifier + shift + arrows = move windows;
  - modifier + number = workspace/layout;
  - modifier + enter = spawn/promote/open;
  - modifier + q/backspace-ish = close/remove.

But none of these know about Groupy tabs, Codex thread state, unread completion dots, VS Code duplicated workspaces, or the user’s “Codex cockpit” behavior.

We should steal the grammar, not the entire architecture.

## Proposed mental model

```text
Ctrl+number
  Navigate tabs inside the current Groupy group.

Ctrl+Shift+Tab
  Navigate Groupy groups / visible Codex columns on the current monitor.

Ctrl+Shift+1/2/3/4
  Shape the current monitor into 1/2/3/4 Codex columns.

Ctrl+Shift+Enter
  Split/promote current tab/chat into its own Groupy group/column.

Ctrl+Shift+Backspace
  Merge current side group back into the main/home group on the same monitor.

Ctrl+Shift+0
  Merge/collapse all Codex/Groupy groups on this monitor back into one main group.
```

The user confirmed `Ctrl+Shift+1/2/3` does not conflict with their VS Code workflow, so do not over-worry about those.

## Proposed v1 keybinds

Start with safe layout/focus only:

```text
Ctrl+Shift+Tab
  Cycle focus through VS Code/Groupy groups on the current monitor.

Ctrl+Shift+1
  Focus mode: maximize current group on its monitor.

Ctrl+Shift+2
  Arrange current monitor’s VS Code/Groupy groups into 2 columns.

Ctrl+Shift+3
  Arrange current monitor’s VS Code/Groupy groups into 3 columns.

Ctrl+Shift+4
  Arrange current monitor’s VS Code/Groupy groups into 4 columns.
```

Important:

- These should apply only to the monitor containing the focused VS Code/Groupy group.
- Do not move windows across monitors unless the command explicitly says to.
- Preserve current Groupy membership in v1.
- Use Win32 `SetWindowPos`, monitor work areas, and foreground/focus APIs rather than sending `Win+Arrow` keystrokes.
- Smoothness matters. Do not poll heavily or do UI Automation scans during drag/layout.

Suggested layout behavior:

```text
Ctrl+Shift+1
  Maximize or fill monitor work area with current Groupy/VS Code group.
  Leave other groups alone or optionally move behind/minimize later.

Ctrl+Shift+2
  Pick the two most relevant VS Code/Groupy groups on current monitor.
  Arrange left/right columns.

Ctrl+Shift+3
  Pick three most relevant groups on current monitor.
  Arrange equal columns.

Ctrl+Shift+4
  Pick four most relevant groups on current monitor.
  Arrange equal columns or 2x2 only if user later prefers.
```

For 2/3/4 columns, equal columns are the default unless sidecar mode is involved.

## “Most relevant group” ordering

This needs to feel predictable.

Candidate ordering:

1. focused/current group first;
2. most-recently-focused groups on the same monitor;
3. visible groups on that monitor left-to-right;
4. optionally prioritize yellow/running or green/completed chats when asked.

The helper should maintain a lightweight MRU list of Groupy/VS Code group HWNDs based on foreground events.

Do not infer too much from one-time enumeration order.

## Monitor awareness

The user has 3 monitors.

All layout commands should be monitor-local by default:

```text
Current monitor = monitor containing the foreground VS Code/Groupy group.
```

Need to detect:

- monitor rectangles;
- monitor work areas excluding taskbars;
- which Groupy/VS Code groups are on which monitor;
- foreground group’s monitor;
- current group’s bounds.

Potential implementation:

- Use `System.Windows.Forms.Screen.AllScreens` for monitor/workarea basics.
- Use Win32 `MonitorFromWindow` / `GetMonitorInfo` if precision is needed.
- Use DWM/window rect functions to account for invisible borders if necessary.

Possible future monitor commands:

```text
Ctrl+Shift+Alt+Left
  Move current Groupy/VS Code group to previous monitor, preserving relative layout.

Ctrl+Shift+Alt+Right
  Move current Groupy/VS Code group to next monitor, preserving relative layout.
```

Do not implement monitor movement before current-monitor layouts feel solid.

## Group focus cycling

Desired:

```text
Ctrl+Shift+Tab
  Cycle VS Code/Groupy groups on the current monitor.
```

This should not cycle individual Groupy tabs. `Ctrl+number` already does that well.

Possible behavior:

- If multiple visible groups on current monitor, focus next group by left-to-right order or MRU.
- User probably expects “the other column” when in 2-column mode.
- In 3/4 column mode, left-to-right cycling may be easiest to understand.
- Optionally wrap to other monitors only if current monitor has one group, but be careful.

Potential variants:

```text
Ctrl+Shift+Tab
  next group on current monitor

Ctrl+Shift+Alt+Tab
  next group across all monitors
```

But keep v1 simple.

## Sidecar mode idea

This may be more valuable than generic tab splitting.

The user wants:

> “I’m working in a repo, and real quick on the side I want another Codex chat for the same workspace. It should feel like it lives inside the same window.”

The illusion:

```text
┌──────────────────────────────────────────────┬──────────────┐
│ Main VS Code workspace                       │ Side Codex    │
│ editor/files/terminal/current chat maybe     │ chat only     │
│                                              │              │
└──────────────────────────────────────────────┴──────────────┘
```

Technically this can be two VS Code windows:

1. Duplicate current workspace into a new VS Code window.
2. Position main window on the left.
3. Position duplicate narrow on the right.
4. Open/focus Codex view in the side window.
5. Hide as much VS Code chrome as practical.
6. Rename/mark the side window as a sidecar.

Suggested keybinds:

```text
Ctrl+Shift+=
  Add/open sidecar Codex chat for current workspace.

Ctrl+Shift+-
  Close/remove focused sidecar, or close the sidecar attached to current main window.
```

Sidecar layout sizing:

```text
sidecarWidth = clamp(monitorWidth * 0.32, 420, 620)
gap = 8 px
mainWidth = monitorWidth - sidecarWidth - gap
```

Sidecar behavior:

- Same monitor as current main group.
- Main window remains broad/normal.
- Sidecar is narrow and Codex-focused.
- Do not try to literally make it the same Groupy tab initially. It should be visually adjacent and logically paired.
- Store sidecar relationship in local runtime state keyed by main window/workspace/group.

Potential sidecar state file:

```text
work\GroupyLayoutState.json
```

Keep state local and ignored.

Possible sidecar titles:

```text
Sidecar · <workspace>
Sidecar · <chat title>
↳ <chat title>
```

Need to be careful because title-sync helper may overwrite native captions. A sidecar marker may need to live in separate state rather than the window title.

## Sidecar implementation notes

Duplicating workspace is already partly solved by existing helpers:

- `GroupySeparateWindowHotkey.ps1` duplicates current workspace and separates it.
- VS Code can open folders/workspaces in new windows via `code`.

Need to investigate reliable ways to make sidecar “chat-only”:

- VS Code command to open Codex view.
- Keyboard shortcut into Codex extension view.
- Hide sidebar/editor/panel/activity bar if possible.
- Maybe use command palette / VS Code CLI / automation.
- Maybe not worth perfecting v1; merely focusing Codex in a narrow window may be enough.

Possible UI operations:

- toggle Activity Bar visibility;
- toggle Primary Side Bar visibility;
- toggle Panel visibility;
- focus Codex view;
- zoom/reset if needed.

Avoid brittle keystroke chains if a VS Code command URI or extension command can be invoked more reliably.

## Split / merge Groupy membership

This is the magical but fragile layer.

Potential commands:

```text
Ctrl+Shift+Enter
  Split/promote current VS Code tab/chat into its own Groupy group/column.

Ctrl+Shift+Backspace
  Merge current group into main/home group on same monitor.

Ctrl+Shift+0
  Merge all groups on current monitor into main/home group.
```

### Ctrl+Shift+Enter

Meaning:

```text
Take the current VS Code tab/window out of this Groupy group and make it its own visible column.
```

Example:

```text
[ A | B | C | D ]
```

Focused tab is `C`.

After `Ctrl+Shift+Enter`:

```text
[ A | B | D ]     [ C ]
```

Then auto-run a 2-column layout.

### Ctrl+Shift+Backspace

Meaning:

```text
Merge the current side group back into the main group on this monitor.
```

Example:

```text
[ A | D ]     [ C ]     [ B ]
```

Focused group is `[ B ]`.

After `Ctrl+Shift+Backspace`:

```text
[ A | D | B ]     [ C ]
```

Then auto-run a 2-column layout.

### Ctrl+Shift+0

Meaning:

```text
Merge all VS Code/Groupy groups on the current monitor into the main/home group.
```

This is the escape hatch:

```text
Things are spread out.
Press Ctrl+Shift+0.
Everything comes home.
Press Ctrl+Shift+1.
Main focus.
```

This command is powerful and potentially disruptive, so it should be implemented only after single-group merge is reliable.

## Defining “main group”

This is important for merge behavior.

Options:

### Option A: leftmost group on current monitor

Pros:

- visible and predictable;
- no hidden state required;
- intuitive in column layouts.

Cons:

- if user rearranges windows manually, “main” may change unexpectedly.

### Option B: home group tracked in local state

Pros:

- matches “original group before splitting”;
- better for sidecar/pair workflows.

Cons:

- state can go stale;
- needs cleanup when windows close/reopen.

Recommendation:

- v1 merge experiments: use leftmost group.
- later sidecar: track explicit home/sidecar relationship.

## Activity-state navigation ideas

Because this repo already knows yellow/green Codex activity state, add navigation commands later:

```text
Ctrl+Shift+Y
  Focus next running/yellow Codex chat.

Ctrl+Shift+G
  Focus next completed/green unread Codex chat.
```

This turns activity dots from visual indicators into an action surface.

Need to reuse/read whatever state `GroupyCodexActivityDots.ps1` writes or centralize its model.

Potential behavior:

- scope to current monitor first;
- if none found, cycle globally;
- bring target Groupy group/window to foreground;
- select the exact tab if target chat is inside a group.

This would be a genuinely useful daily command.

## Command palette / cheat sheet idea

Borrow from PowerToys Shortcut Guide.

Potential command:

```text
Ctrl+Shift+Space
  Show tiny Codex layout cheat sheet / command overlay.
```

Overlay content:

```text
1 Focus    2 Two cols    3 Three cols    4 Four cols    0 Merge all
Tab Next group    Enter Split    Backspace Merge
= Sidecar    - Close sidecar    Y Running    G Done
```

This does not need to be fancy. It could be a click-through WPF overlay that disappears after 2 seconds or on key release.

This is optional, but it would make the system easier to learn.

## Possible final command vocabulary

Core daily commands:

```text
Ctrl+Shift+Tab
  Next Groupy/VS Code group on current monitor.

Ctrl+Shift+1
  Focus/maximize current group.

Ctrl+Shift+2
  Arrange current-monitor groups into 2 columns.

Ctrl+Shift+3
  Arrange current-monitor groups into 3 columns.

Ctrl+Shift+4
  Arrange current-monitor groups into 4 columns.
```

Sidecar:

```text
Ctrl+Shift+=
  Add sidecar Codex chat for current workspace.

Ctrl+Shift+-
  Remove/close sidecar.
```

Membership magic:

```text
Ctrl+Shift+Enter
  Split/promote current tab/chat into own group/column.

Ctrl+Shift+Backspace
  Merge current group into main/home group.

Ctrl+Shift+0
  Merge all groups on current monitor into main/home group.
```

Activity navigation:

```text
Ctrl+Shift+Y
  Focus next yellow/running Codex chat.

Ctrl+Shift+G
  Focus next green/completed Codex chat.
```

Monitor movement:

```text
Ctrl+Shift+Alt+Left
  Move current group to previous monitor.

Ctrl+Shift+Alt+Right
  Move current group to next monitor.
```

Help:

```text
Ctrl+Shift+Space
  Show layout shortcut cheat sheet.
```

## Recommended implementation path

### Phase 1: safe layout/focus helper

Implement or expand `GroupyWindowShortcuts.ps1`.

Add:

- `Ctrl+Shift+Tab`;
- `Ctrl+Shift+1`;
- `Ctrl+Shift+2`;
- `Ctrl+Shift+3`;
- maybe `Ctrl+Shift+4`.

Responsibilities:

- identify current monitor;
- enumerate visible Groupy/VS Code groups on that monitor;
- maintain MRU;
- focus next group;
- arrange selected groups into equal columns.

Validation:

- no lag while typing;
- no lag while dragging;
- no duplicate hotkey registration;
- hotkeys only consume when active context is VS Code/Groupy if needed;
- works across 3 monitors.

### Phase 2: sidecar v1

Add:

- `Ctrl+Shift+=`;
- `Ctrl+Shift+-`.

Responsibilities:

- duplicate current workspace;
- open/focus Codex;
- place main + sidecar in split layout;
- track pair in local state;
- close/remove sidecar.

Do not obsess over perfect “same Groupy tab” illusion initially.

### Phase 3: activity navigation

Add:

- `Ctrl+Shift+Y`;
- `Ctrl+Shift+G`.

Reuse activity dots model/state to focus exact target chats.

### Phase 4: split/merge Groupy membership

Add:

- `Ctrl+Shift+Enter`;
- `Ctrl+Shift+Backspace`;
- `Ctrl+Shift+0`.

This is likely the hardest part. Use experiments/probes, preserve evidence, and avoid breaking the daily workflow.

## Implementation constraints / non-negotiables

- Do not make `Ctrl+1` through `Ctrl+9` slower.
- Do not make manual Groupy clicking slower.
- Do not cause VS Code lag while typing, scrolling, or dragging windows.
- Avoid frequent UI Automation scans.
- Use cached state and event hooks where possible.
- Keep logs concise and non-fatal.
- Do not delete experiment files.
- Do not rely on OCR.
- Do not broaden hotkeys globally if they interfere outside VS Code/Groupy.
- Always keep a safe stop path via supervisor/wrappers.

## Useful diagnostics to keep in mind

General helper status:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
```

Process command lines:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'groupy-vscode-codex-tabs' } |
  Select-Object ProcessId,CommandLine
```

Parse check:

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

## Tone for the next agent

Approach this as a solvable automation/reverse-engineering project.

Be pragmatic:

- First discover the actual Groupy/VS Code/Windows behavior.
- Prefer small probes over assumptions.
- Implement one keybind at a time.
- Test each keybind in real windows.
- Keep the daily workflow stable.
- When something seems impossible, find the actual mechanism or boundary before concluding.

The user wants a magical workflow, but not at the cost of lag or brittle chaos. The right answer is incremental, hacky, measured, and ambitious.
