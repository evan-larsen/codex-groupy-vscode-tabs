---
name: setup-codex-groupy-vscode-tabs
description: Set up, configure, validate, repair, or migrate the personal Windows Codex + VS Code + Stardock Groupy tab workflow from this repo. Use when asked to install the helpers on another machine, configure Groupy settings, install the startup supervisor, troubleshoot missing tab titles/dots/hotkeys/usage badge, or make an AI-run setup for codex-groupy-vscode-tabs.
---

# Setup Codex Groupy VS Code Tabs

## Scope

Use this skill to install or repair the Windows workflow in `codex-groupy-vscode-tabs`:

- VS Code windows grouped as Groupy tabs.
- Groupy tabs named from the active Codex chat.
- Yellow/green Codex activity dots across visible Groupy tabs.
- Active-window context/weekly usage badge.
- `Ctrl+1`-`Ctrl+9`, `Ctrl+Shift+N`, and `Ctrl+Shift+R` helper hotkeys.
- A Windows Scheduled Task that starts the helper supervisor at user logon.
- The Scheduled Task should run `scripts\Start-CodexGroupyTools.ps1`; that wrapper starts the long-running supervisor detached and exits cleanly.

This is Windows-specific and assumes Stardock Groupy 2, Windows PowerShell 5.1, VS Code, the ChatGPT/Codex VS Code extension, Node.js, and Git.

## Safety rules

- Prefer dry-run/inspect commands before writing registry settings.
- Back up `HKCU\Software\Stardock\Groupy` before applying Groupy settings.
- Do not delete repo evidence, logs, docs, or old experiments.
- Do not manually clean `work\` unless the user asks; logs are useful diagnostics.
- Do not make global hotkeys consume keys outside VS Code/Groupy.
- Keep all-groups dots in cached mode, not the old direct all-groups polling mode.
- Keep private Node Inspector/orange needs-input paths disabled unless the user explicitly asks to revisit them.

## Repository layout

Expect this layout:

```text
README.md
SETUP.md
scripts\
  Install-CodexGroupyEnvironment.ps1
  CodexGroupySupervisor.ps1
  Start-CodexGroupyTools.ps1
  Stop-CodexGroupyTools.ps1
  CodexGroupyTabSync.ps1
  CodexChatRenameHotkey.ps1
  GroupyNumberTabs.ps1
  GroupySeparateWindowHotkey.ps1
  GroupyUsageOverlay.ps1
  GroupyCodexActivityDots.ps1
  Get-CodexUsage.ps1
  CodexVsCodeLiveRenameBridge.js
docs\
archive\
work\
```

Use `SETUP.md` as the human-facing guide. Use this skill as the agent-facing procedure.

## Standard setup workflow

1. Open Windows PowerShell in the repo root.
2. Confirm prerequisites:

```powershell
git --version
node --version
code --version
Get-ItemProperty 'HKLM:\Software\WOW6432Node\Stardock\Groupy' -ErrorAction SilentlyContinue
Get-ItemProperty 'HKLM:\Software\Stardock\Groupy' -ErrorAction SilentlyContinue
```

3. If the repo is not present, clone it:

```powershell
cd "$env:USERPROFILE\Documents"
git clone https://github.com/evan-larsen/codex-groupy-vscode-tabs.git groupy-vscode-codex-tabs
cd .\groupy-vscode-codex-tabs
```

4. Allow scripts for the current shell only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

5. Dry-run the environment installer:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1
```

6. Apply the known-good Groupy settings, install the startup task, and start helpers:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1 -Apply
```

7. If Groupy does not reflect settings immediately, sign out/in or rerun with explicit Groupy UI restart:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1 -Apply -RestartGroupy
```

8. Validate:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
Get-ScheduledTask -TaskName CodexGroupySupervisor
```

## Known-good Groupy settings

The installer writes these HKCU values. Treat them as user-level settings and always back up before writing.

```text
HKCU\Software\Stardock\Groupy\Groupy.ini\Groupy
  AllowHideWin11Tabs = 0
  AlsoRegisterCtrlKeys = 1
  AlsoRegisterRenameKey = 0
  AlwaysPaintSingleTab = 1
  AskedAboutDelayGrouping = 1
  AutoHideMode = 0
  DefinedHotKeyRename = 458865
  ExplorerMiddleButton = 0
  ForceShowAddOnAll = 1
  G2_ActiveBarColour = 1184274
  G2_ActiveTabColour = 0xFFFFFFFF
  G2_ForceNoAnimsOnTabs = 0
  G2_InactiveBarColour = 2039583
  G2_InactiveTabColour = 0xFFFFFFFF
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
  NewInstallDone = 1
  SetupDefaultRules = 1
  SetupDefaultRules2 = 1
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

The Groupy rename-tab hotkey must be `Ctrl+Alt+Shift+F2`. The helper sends it as `^%+{F2}`.

## Validation checklist

Run:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
```

Confirm each component is running:

- Codex / Groupy supervisor
- Codex tab-title sync
- Codex chat rename `Ctrl+Shift+R`
- Groupy `Ctrl+1` through `Ctrl+9`
- Separate-group `Ctrl+Shift+N`
- Usage/context overlay
- Codex activity dots

Then manually test:

1. Open two VS Code windows in one Groupy group.
2. Open a different Codex chat in each.
3. Confirm the Groupy tab titles become the Codex chat names.
4. Start a Codex task; confirm yellow appears quickly.
5. Switch away before completion; confirm green appears when complete.
6. Focus the completed tab; confirm green clears.
7. Confirm the active Groupy strip shows the usage badge.
8. Press `Ctrl+1`/`Ctrl+2` inside VS Code and confirm tab switching.
9. Press `Ctrl+1`/`Ctrl+2` outside VS Code and confirm the foreground app receives the keys.
10. Press `Ctrl+Shift+R` in a Codex chat and confirm rename persists.
11. Press `Ctrl+Shift+N` and confirm the current workspace opens in a separated Groupy group.

## Diagnostics

Use these first:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -Status
Get-Content .\work\CodexGroupySupervisor.log -Tail 80
Get-Content .\work\CodexGroupyTabSyncRuntime.log -Tail 80
Get-Content .\work\ActivityDotsRuntime.log -Tail 120
Get-Content .\work\CodexChatRenameHotkey.log -Tail 80
```

Inspect individual systems:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -Inspect
.\scripts\GroupyNumberTabs.ps1 -Inspect
.\scripts\GroupyCodexActivityDots.ps1 -Inspect
.\scripts\GroupyUsageOverlay.ps1 -InspectContext
```

Parse-check PowerShell runtime scripts:

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

## Rollback

The installer writes backups to `backups\groupy-settings\` and that folder is ignored by Git.

Restore a backup:

```powershell
.\scripts\Install-CodexGroupyEnvironment.ps1 -RestoreBackup .\backups\groupy-settings\GroupySettings-YYYYMMDD-HHMMSS.reg
```

Stop helpers:

```powershell
.\scripts\Stop-CodexGroupyTools.ps1
```

Remove startup task:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -UninstallStartupTask
```

## Common fixes

- If Groupy titles do not follow VS Code, close/reopen the affected VS Code window; manually renamed Groupy tabs can become custom titles.
- If dots are missing, ensure the supervisor started `GroupyCodexActivityDots.ps1 -AllGroupsCached`, not legacy `-AllGroups`.
- If `Ctrl+Shift+R` does not persist, inspect `work\CodexChatRenameHotkey.log` and reload the VS Code extension host.
- If VS Code feels laggy, inspect helper processes and logs before changing polling intervals.
- If setup changed Groupy settings but the UI looks stale, restart Groupy, sign out/in, or reboot.
