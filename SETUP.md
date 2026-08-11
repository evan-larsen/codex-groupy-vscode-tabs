# Setup Guide: Codex + VS Code + Groupy Tabs

This is the full new-machine setup guide for this repo. The goal is to recreate the same workflow:

- one Codex chat per VS Code window;
- those VS Code windows grouped as Groupy tabs;
- Groupy tabs automatically named after the selected Codex chat;
- yellow/green activity dots across visible Groupy tab strips;
- `Ctrl+1` through `Ctrl+9` switches exact Groupy tab positions;
- `Ctrl+Shift+N` duplicates the current VS Code workspace into a new detached Groupy group;
- `Ctrl+Shift+R` renames the current Codex chat;
- a subtle context/weekly usage badge appears on the active Groupy strip;
- one supervisor keeps all helpers running and starts automatically at Windows logon.

This setup is intentionally Windows-specific and tuned for Groupy 2.3.x.

## Known-good reference environment

This repo was built and validated on:

- Windows 11
- Windows PowerShell 5.1 via `powershell.exe`
- Stardock Groupy 2.3.1.1
- VS Code installed at `%LOCALAPPDATA%\Programs\Microsoft VS Code`
- ChatGPT/Codex VS Code extension installed under `%USERPROFILE%\.vscode\extensions\openai.chatgpt-*`
- Node.js available on `PATH`
- Git for Windows available on `PATH`

Reference tool paths from the original machine:

```text
PowerShell: C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe
VS Code CLI: C:\Users\evanl\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd
Node: C:\Program Files\nodejs\node.exe
Git: C:\Users\evanl\AppData\Local\Programs\Git\cmd\git.exe
Groupy: C:\Program Files (x86)\Stardock\Groupy2
```

New machines do not need identical absolute paths, but these executables must be discoverable.

## Install prerequisites

Install these first:

1. Stardock Groupy 2.
2. Visual Studio Code.
3. The ChatGPT/Codex VS Code extension.
4. Node.js.
5. Git for Windows.

Then verify from Windows PowerShell:

```powershell
powershell.exe -NoProfile
git --version
node --version
code --version
```

If `code` is missing, open VS Code and run **Shell Command: Install 'code' command in PATH** if available, or use the full `code.cmd` path in your own scripts.

## Clone the repo

Choose a stable path. The original path is:

```text
C:\Users\evanl\Documents\groupy-vscode-codex-tabs
```

Clone:

```powershell
cd "$env:USERPROFILE\Documents"
git clone https://github.com/evan-larsen/codex-groupy-vscode-tabs.git groupy-vscode-codex-tabs
cd .\groupy-vscode-codex-tabs
```

Allow scripts for the current PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

You do not need to permanently weaken the machine execution policy; the supervisor launches helpers with `-ExecutionPolicy Bypass`.

## Automated setup path

This repo includes a conservative setup script for new machines:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1
```

With no flags, it is a dry run. It detects Groupy, prints the current vs desired settings, and does not write anything.

To back up your current Groupy settings, apply the known-good Groupy values, install the Windows logon Scheduled Task, and start the helper supervisor:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1 -Apply
```

Backups are written to:

```text
backups\groupy-settings\
```

That folder is intentionally ignored by Git because registry exports are local machine state.

To create only a backup:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1 -BackupOnly
```

To restore a backup:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1 -RestoreBackup .\backups\groupy-settings\GroupySettings-YYYYMMDD-HHMMSS.reg
```

If Groupy does not pick up the new settings immediately, sign out/in, reboot, or explicitly ask the script to restart the Groupy UI/control process:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1 -Apply -RestartGroupy
```

For AI-assisted setup, this repo also includes an agent skill at:

```text
.agents\skills\setup-codex-groupy-vscode-tabs\SKILL.md
```

An agent can use that skill as the full setup/validation playbook.

## Configure Groupy

Open **Stardock Groupy 2 Configuration**.

Use these behavioral settings:

- Group only selected/included apps, not every app globally.
- Include `Code.exe` in Groupy.
- Always show tabs for `Code.exe`.
- Use square tabs.
- Hide Groupy icon on tabs.
- Hide close buttons on tabs.
- Do not merge the Groupy strip into the native title bar.
- Keep Groupy tab animations enabled.
- Configure Groupy's **Rename Tab** hotkey as:

```text
Ctrl + Alt + Shift + F2
```

The scripts send this as PowerShell SendKeys syntax:

```text
^%+{F2}
```

### Original machine Groupy registry snapshot

These values are provided as a reference for matching the original setup. Prefer the Groupy UI where possible.

```text
HKCU\Software\Stardock\Groupy\Groupy.ini\Groupy
  AllowHideWin11Tabs = 0
  AlsoRegisterCtrlKeys = 1
  AlsoRegisterRenameKey = 0
  AlwaysPaintSingleTab = 1
  AutoHideMode = 0
  DefinedHotKeyRename = 458865
  ForceShowAddOnAll = 1
  G2_ActiveBarColour = 1184274
  G2_ActiveTabColour = -1
  G2_ForceNoAnimsOnTabs = 0
  G2_InactiveBarColour = 2039583
  G2_InactiveTabColour = -1
  G2_NoSepLine = 0
  G2_OldNewTabMode = 1
  G2_SquareTabs = 1
  GroupNewCtrl = 1
  GroupyGroupMode = 0
  GroupyHotKey = 1
  HideGroupyIcon = 1
  HideTitleText = 0
  InclusionListMode = 1
  MergeTitlebar = 0
  NeverShowClose = 1
  ShowCloseAll = 0
  ShowCloseOnActive = 0
  ShowCloseOnAll = 0
  ShowIcon = 0
  VariableTabSizes = 0

HKCU\Software\Stardock\Groupy\Groupy.ini\Groupy\AlwaysShowTabs
  Code.exe = 1

HKCU\Software\Stardock\Groupy\Groupy.ini\Groupy\Exclusions
  Code.exe = 1

HKCU\Software\Stardock\Groupy\Groupy.ini\Groupy\TabBackgroundMode
  Code.exe = 1
```

The `Exclusions\Code.exe = 1` value is not a typo in this setup; Groupy's registry naming is a little odd when inclusion mode is enabled.

## Configure VS Code and Codex

1. Install and sign into the ChatGPT/Codex VS Code extension.
2. Open the Codex side panel at least once.
3. Start or open a Codex chat.
4. For the intended workflow, use one VS Code window per Codex chat.
5. Let Groupy group those VS Code windows into tabs.

Important behavior:

- The title-sync helper reads the visible Codex webview with Windows UI Automation.
- It does not infer the active window from the global Codex database alone.
- Fresh Groupy tabs should follow the VS Code window caption automatically.
- If you manually rename a Groupy tab with Groupy's UI, Groupy may mark it custom and stop following the VS Code caption. Close/reopen that VS Code window to get a fresh, auto-following tab.

## Start the full helper stack

From the repo folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-CodexGroupyTools.ps1
```

Check status:

```powershell
.\scripts\Start-CodexGroupyTools.ps1 -Status
```

Expected components:

```text
Codex / Groupy supervisor
Codex tab-title sync
Codex chat rename Ctrl+Shift+R
Groupy Ctrl+1 through Ctrl+9
Separate-group Ctrl+Shift+N
Usage/context overlay
Codex activity dots
```

The compatibility start script launches `CodexGroupySupervisor.ps1 -Start` in the background. The supervisor then starts and monitors the daily helpers.

## Install automatic startup

Install the per-user Scheduled Task:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -InstallStartupTask
```

Verify:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
Get-ScheduledTask -TaskName CodexGroupySupervisor
```

Expected task action:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "<repo>\scripts\CodexGroupySupervisor.ps1" -Start
```

The task runs at Windows user logon. It does not require admin. It is configured to ignore duplicate starts, so running the task manually while the supervisor is already alive should not create duplicate helpers.

To remove automatic startup:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -UninstallStartupTask
```

To stop everything manually:

```powershell
.\scripts\Stop-CodexGroupyTools.ps1
```

To restart everything manually:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Restart
```

## Visual design and colors

### Activity dots

Daily mode:

```powershell
.\scripts\GroupyCodexActivityDots.ps1 -AllGroupsCached
```

Defaults:

```text
Dot diameter: 7 px
Right padding inside tab: 9 px
Update timer in cached all-groups mode: 1000 ms
Overlay: click-through WPF layer, one per visible Groupy strip
Drag behavior: hides while a VS Code/Groupy window is being moved, then redraws after move end
```

Colors:

```text
Working yellow: #ffcd14   RGB(255, 205, 20)
Finished green: #43c96d   RGB(67, 201, 109)
Optional input orange: #ff9123   RGB(255, 145, 35)
```

Current daily behavior:

- yellow dot while a Codex turn is working;
- green dot for unread completed work in a background tab;
- focusing that exact VS Code window clears green;
- no dot when no Codex chat can be resolved;
- orange/needs-input is intentionally disabled unless `-EnableNeedsUserBridge` is passed.

### Usage/context badge

Daily mode:

```powershell
.\scripts\GroupyUsageOverlay.ps1
```

Defaults:

```text
Refresh interval: 60 seconds
Right margin: 16 px
Window size: 290 x 29
Font: Segoe UI, 12 px, normal weight
Text color: #dcdcdc   RGB(220, 220, 220)
```

Expected text resembles:

```text
Codex ● 3  ● 1  ● 2      Context 78% left  |  Weekly 91% · 6d
```

The white dot count is all visible/resolved Codex tabs, the yellow count is running turns, and the green count is
unread completed turns across all visible VS Code Groupy windows. The badge is click-through and hides when the
foreground window is not a grouped VS Code window.

## Hotkeys

This repo registers:

```text
Ctrl+1 through Ctrl+9
  Select exact left-to-right visible Groupy tab positions when a Groupy-linked VS Code window is focused.
  Outside VS Code, the helper passes the original Ctrl+number chord through to the foreground app.

Ctrl+Shift+N
  Duplicate the current VS Code workspace and physically detach it into a separate Groupy group.

Ctrl+Shift+R
  Rename the currently selected Codex chat.
```

Groupy itself must also have:

```text
Ctrl+Alt+Shift+F2
  Groupy's built-in Rename Tab hotkey.
```

If a hotkey fails to register, another app is probably already using it. Check the relevant runtime log in `work\`.

## How each helper works

The supervisor owns these helpers:

```text
CodexGroupyTabSync.ps1 -WatchAutoTitle
  Reads the selected Codex chat title from the foreground VS Code UI Automation tree and writes it to the VS Code window caption.

CodexChatRenameHotkey.ps1
  Registers Ctrl+Shift+R and renames the selected Codex chat through VS Code's live Codex connection when available, with a detached persisted fallback.

GroupyNumberTabs.ps1
  Registers Ctrl+1 through Ctrl+9 and reads GroupyCtrl.exe's live ordered tab HWND array for exact tab selection.

GroupySeparateWindowHotkey.ps1
  Registers Ctrl+Shift+N, duplicates the current VS Code workspace, then uses Groupy's tab-drag behavior to separate it.

GroupyUsageOverlay.ps1
  Shows active chat context usage plus weekly Codex quota usage.

GroupyCodexActivityDots.ps1 -AllGroupsCached
  Watches Codex lifecycle state and renders yellow/green dots across visible Groupy strips.
```

All helpers are local. They do not use OCR for the normal path, do not scrape cookies, and do not need API keys.

## Validation checklist

Run this after setup:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
```

Then verify manually:

1. Open two VS Code windows and let Groupy group them.
2. Open a different Codex chat in each VS Code window.
3. Confirm each Groupy tab title becomes the Codex chat name.
4. Press `Ctrl+1`, `Ctrl+2`, etc. while VS Code is focused; the exact Groupy tab should activate.
5. Start a Codex task in one tab; a yellow dot should appear quickly.
6. Switch to another tab before the task finishes; after completion, the first tab should turn green.
7. Focus the completed tab; the green dot should clear.
8. Press `Ctrl+Shift+R` in a Codex chat; rename it and confirm the visible title updates.
9. Press `Ctrl+Shift+N`; the current VS Code workspace should duplicate into a separated Groupy group.
10. Confirm the usage/context badge appears on the active Groupy strip.

## Diagnostic commands

Status:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
```

Logs:

```powershell
Get-Content .\work\CodexGroupySupervisor.log -Tail 80
Get-Content .\work\CodexGroupyTabSyncRuntime.log -Tail 80
Get-Content .\work\CodexChatRenameHotkey.log -Tail 80
Get-Content .\work\ActivityDotsRuntime.log -Tail 80
```

Inspect title resolution:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -Inspect
```

Inspect Groupy tab order:

```powershell
.\scripts\GroupyNumberTabs.ps1 -Inspect
```

Inspect activity-dot mapping:

```powershell
.\scripts\GroupyCodexActivityDots.ps1 -Inspect
```

Inspect usage/context resolution:

```powershell
.\scripts\GroupyUsageOverlay.ps1 -InspectContext
```

Parse-check runtime PowerShell files:

```powershell
$failed = $false
foreach ($file in Get-ChildItem -File -Filter *.ps1 | Sort-Object Name) {
  $tokens=$null; $errors=$null
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

## Troubleshooting

### Nothing starts

Run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\CodexGroupySupervisor.ps1 -Status
.\scripts\CodexGroupySupervisor.ps1 -Restart
```

If scripts are blocked because they came from the internet:

```powershell
Get-ChildItem -Recurse -File | Unblock-File
```

### Scheduled Task does not start after reboot

Verify:

```powershell
Get-ScheduledTask -TaskName CodexGroupySupervisor
(Get-ScheduledTask -TaskName CodexGroupySupervisor).Actions
```

Reinstall:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -UninstallStartupTask
.\scripts\CodexGroupySupervisor.ps1 -InstallStartupTask
```

The task starts at user logon, not before login.

### Groupy tab titles do not update

Check:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -Inspect
```

Likely causes:

- the Codex view is on Home/new-chat, not an actual saved chat;
- the Groupy tab was manually renamed and no longer follows the VS Code window caption;
- VS Code changed its UI Automation tree after an extension update;
- Groupy is not configured to include/always-show-tabs for `Code.exe`.

Fix manually renamed tabs by closing/reopening that VS Code window so Groupy creates a fresh auto-following tab.

### Ctrl+Shift+R rename does not persist live in VS Code

The rename helper prefers VS Code's live extension-host Inspector bridge. If VS Code does not expose a usable Inspector endpoint, it falls back to a detached persisted-name update and native window caption update.

Check:

```powershell
Get-Content .\work\CodexChatRenameHotkey.log -Tail 80
```

If the log says no live Codex VS Code connection was prepared, open the Codex view in VS Code and reload/restart the VS Code extension host.

### Activity dots missing or stale

Check:

```powershell
Get-Content .\work\ActivityDotsRuntime.log -Tail 120
.\scripts\GroupyCodexActivityDots.ps1 -Inspect
```

Expected daily mode is `-AllGroupsCached`. Do not use legacy `-AllGroups` for daily startup; it was retained only for investigation.

### VS Code feels laggy

The current low-lag defaults are:

- supervisor health check every 8 seconds;
- cached all-groups activity dots at 1000 ms;
- usage overlay placement/update throttled;
- title sync is event-gated and avoids full UI Automation scans unless needed;
- dots hide while moving/dragging windows.

If lag appears, check CPU by helper process:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'groupy-vscode-codex-tabs' } |
  Select-Object ProcessId,CommandLine
```

Then inspect the relevant log in `work\`.

## Repo layout

Runtime files live in `scripts\`:

```text
scripts\Install-CodexGroupyEnvironment.ps1
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

Top-level docs:

```text
README.md
SETUP.md
```

Detailed engineering docs live in `docs\`:

```text
docs\REVERSE_ENGINEERING_LOG.md
docs\ACTIVITY_DOTS_AUDIT_HANDOFF.md
docs\ACTIVITY_DOTS_LIVE_LIFECYCLE_HANDOFF.md
docs\ACTIVITY_DOTS_ALL_GROUPS_IMPLEMENTATION_PLAN.md
```

Preserved local evidence/experiments:

```text
archive/
```

Active logs:

```text
work/
```

The GitHub repo intentionally ignores active logs, screenshots, vendored reverse-engineering Python tooling, and compiled binaries.

## Updating the repo

Pull latest changes:

```powershell
git pull
.\scripts\CodexGroupySupervisor.ps1 -Restart
```

Check what changed locally:

```powershell
git status
```

Push changes:

```powershell
git add .
git commit -m "Describe the change"
git push
```
