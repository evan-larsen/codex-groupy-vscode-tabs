# Activity Dots Live Lifecycle Handoff

Timestamp: 2026-08-11 09:01 MDT

Workspace:

```text
C:\Users\evanl\Documents\groupy-vscode-codex-tabs
```

This is a follow-up to `ACTIVITY_DOTS_AUDIT_HANDOFF.md`. That original audit/handoff still matters for the Groupy memory layout, old experiments, and baseline constraints. This file captures the successful live-lifecycle implementation and the current state after testing.

## Goal

Reliable per-Groupy-tab Codex activity dots:

- yellow, gently pulsing, while a Codex turn is actively running
- green only for an unread completion
- focusing the exact VS Code window clears green
- no dot for unresolved/non-Codex chat tabs
- orange/needs-input remains disabled unless explicitly revisited
- all-groups rendering remains disabled by default to avoid Groupy/VS Code lag

## Current Result

The live yellow/green behavior now works and has been user-verified:

- yellow appears immediately when a Codex turn starts
- yellow clears immediately when the focused chat completes
- if the chat finishes in the background, it turns green
- focusing that tab clears green
- multiple VS Code extension hosts can now be bridged when they expose an inspector endpoint

The user confirmed:

```text
the yellow dot started IMMEDIATELY
when the message cleared, it removed the yellow dot, IMMEDIATELY
I went into another window, it immediately turned green when you finished
when I opened this tab, it cleared it again
```

## Why The Old File-Based Approach Failed

The rollout JSONL/session-file path is not a reliable real-time signal for yellow.

Observed earlier:

- a 10-30 second delayed terminal task was actively running
- the rollout file still read as previous `finished`
- after task completion, a fresh inspect saw the terminal state

Conclusion: `.codex\sessions\...\rollout-*.jsonl` is acceptable as fallback/recovery, but not as the primary source for live yellow. FileSystemWatcher would not fix that because the file is delayed/buffered.

## Live Architecture

The activity helper now attaches to the VS Code Codex extension's own app-server connection through the extension host's Node inspector endpoint.

Flow:

```text
VS Code Codex extension host
  -> Node inspector websocket
  -> CodexVsCodeLiveRenameBridge.js trace-activity
  -> lifecycle-only JSON lines to PowerShell
  -> GroupyCodexActivityDots.ps1 liveActivityByThread
  -> active Groupy strip overlay
```

Important: a separate `codex.exe app-server` is not sufficient for live status because the VS Code extension has its own app-server/client process and in-memory lifecycle state.

## Relevant Files Changed

### GroupyCodexActivityDots.ps1

Key additions:

- `-DisableLiveLifecycleBridge` switch for diagnostics/fallback
- `$script:liveActivityByThread`
- live bridge startup defaults to `trace-activity`
- `Get-LiveActivityState`
- `Test-LiveLifecycleBridgeReady`
- `Update-LiveThreadActivityFromNotification`
- multi-inspector cache/discovery via `work\CodexInspectorUrl.txt`
- stale rollout `working` is suppressed once a live lifecycle bridge is ready
- `thread/status/changed` object statuses are parsed correctly
- slow update watchdog logs `SLOW UPDATE elapsedMs=...`

The display state now prefers live state:

```text
live thread state -> rollout fallback
```

But once the live bridge is ready, stale file-based `working` is ignored so old unclosed `task_started` entries cannot resurrect yellow.

### CodexVsCodeLiveRenameBridge.js

Key additions/changes:

- existing operations include `prepare`, `rename`, `watch-activity`, `trace-activity`
- `trace-activity` uses the live Codex app-server connection already owned by the VS Code extension
- raw notifications are now filtered to lifecycle-only events:

```text
turn/started
turn/completed
turn/complete
turn/aborted
turn/cancelled
turn/canceled
turn/failed
turn/error
task/started
task/completed
task/complete
task/aborted
task/cancelled
task/canceled
task/failed
task/error
thread/status/updated
thread/status/changed
```

- noisy events like output deltas, agent-message deltas, diff updates, and item command output are ignored
- internal event queue is capped at 500 entries
- still preserves pending/resolved request tracking for the future orange path, but orange remains opt-in from PowerShell

## Evidence From Runtime Log

Successful live yellow:

```text
[08:51:30.859] live-notification method=turn/started status=<none> itemType=<none>
[08:51:30.860] live-thread thread=019fedcc-36fd-74b3-9914-1e5bd82efe79 state=working turn=<none>
[08:51:30.889] strip=0x7094A; visibleTab=0xDE0EEC; dots=14552812|working|0,0,220,31
```

Successful background green and focus clear:

```text
[08:52:03.670] live-thread thread=019fedcc-36fd-74b3-9914-1e5bd82efe79 state=finished turn=<none>
[08:52:03.704] ... dots=14552812|finished|0,0,220,31
[08:52:11.490] ... dots=; ... finished|<none>
```

Second window/live host evidence after another extension host was exposed:

```text
[08:55:58.111] live-thread thread=019fedd6-b77a-70f0-a905-b7428c860b41 state=working turn=<none>
[08:55:58.134] ... dots=1314254|working|220,0,440,31
[08:56:24.953] live-thread thread=019fedd6-b77a-70f0-a905-b7428c860b41 state=finished turn=<none>
[08:56:24.964] ... dots=1314254|finished|220,0,440,31
[08:56:29.090] ... dots=; ... finished|<none>
```

## Current Running State At Handoff

After applying lifecycle-only filtering, the helper was restarted.

Known state from last status:

```text
Codex tab-title sync         running 29432
Groupy Ctrl+1 through Ctrl+9 running 38592
Separate-group Ctrl+Shift+N  running 35976
Usage/context overlay        running 5228
Codex activity dots          running 30000
```

Live bridge processes at that moment:

```text
node PID 40644 -> ws://127.0.0.1:63123/2e4d7c2d-2cb2-47c4-948e-46cc5e572ec4
node PID 27316 -> ws://127.0.0.1:59269/b25ffbcb-6334-48a3-a802-20f107c98842
```

PIDs are naturally volatile. Re-check with:

```powershell
.\Start-CodexGroupyTools.ps1 -Status
Get-CimInstance Win32_Process -Filter "name = 'node.exe'" |
  Where-Object { $_.CommandLine -match 'CodexVsCodeLiveRenameBridge\.js' } |
  Select-Object ProcessId,CreationDate,CommandLine |
  Format-List
```

## Important Commands

Inspect current dots/runtime state:

```powershell
.\GroupyCodexActivityDots.ps1 -Inspect -AllGroups
Get-Content .\work\ActivityDotsRuntime.log -Tail 120
.\Start-CodexGroupyTools.ps1 -Status
```

Restart just activity dots:

```powershell
$helpers = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -match '\-File\s+.*GroupyCodexActivityDots\.ps1' }
foreach ($h in $helpers) { Stop-Process -Id $h.ProcessId -ErrorAction SilentlyContinue }

$bridges = Get-CimInstance Win32_Process -Filter "name = 'node.exe'" |
  Where-Object { $_.CommandLine -match 'CodexVsCodeLiveRenameBridge\.js' }
foreach ($b in $bridges) { Stop-Process -Id $b.ProcessId -ErrorAction SilentlyContinue }

.\Start-CodexGroupyTools.ps1
```

Probe inspector endpoints:

```powershell
$results = @()
$listeners = Get-NetTCPConnection -State Listen |
  Where-Object { $_.LocalAddress -in @('127.0.0.1','::1') }
foreach ($l in $listeners) {
  $hostName = if ($l.LocalAddress -eq '::1') { '[::1]' } else { $l.LocalAddress }
  $url = "http://$hostName`:$($l.LocalPort)/json/list"
  try {
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 1 -ErrorAction Stop
    foreach ($entry in @($r)) {
      if ($entry.type -eq 'node' -and $entry.webSocketDebuggerUrl) {
        $results += [pscustomobject]@{
          Pid = $l.OwningProcess
          Port = $l.LocalPort
          Title = $entry.title
          Ws = $entry.webSocketDebuggerUrl
        }
      }
    }
  } catch {}
}
$results | Format-Table -AutoSize
```

Prepare-check a specific websocket:

```powershell
node .\CodexVsCodeLiveRenameBridge.js prepare "ws://127.0.0.1:PORT/ID"
```

## Multi-Window Notes

VS Code windows can have separate extension hosts. The live dots only work for extension hosts that expose a Node inspector websocket.

Observed progression:

1. Initially only this chat/window had a reachable endpoint.
2. User ran `Developer: Restart Extension Host` in another VS Code window.
3. A second endpoint appeared.
4. Helper spawned a second live bridge.
5. Yellow/green worked for that other tab too.

If a new VS Code window does not show live dots:

1. Focus that VS Code window.
2. Run `Developer: Restart Extension Host`.
3. Wait about 20 seconds.
4. Confirm a new bridge process appears.

Do not enable `-AllGroups` as the default. Rendering is intentionally active-strip only because old all-groups rendering caused Groupy/VS Code lag.

## Freeze / Performance Notes

User saw one brief VS Code freeze after a dot completed. It recovered by itself and was not consistently reproduced.

Likely cause identified and mitigated:

- before the latest patch, `trace-activity` forwarded all raw Codex notifications
- this included high-volume `item/commandExecution/outputDelta`, `agentMessage/delta`, `turn/diff/updated`, etc.
- now the bridge forwards lifecycle-only events and caps its queue at 500

Additional watchdog:

- if a WPF update tick takes at least 750ms, activity helper logs:

```text
SLOW UPDATE elapsedMs=...
```

Check after future freezes:

```powershell
Get-Content .\work\ActivityDotsRuntime.log -Tail 200
```

Cursor movement note:

- user saw a one-off cursor jump, likely their own mouse movement
- activity dots helper has no cursor APIs
- `GroupyWindowShortcuts.ps1` does contain `SetCursorPos`/physical drag logic, but it was not running during inspection
- if cursor jumps recur, check for any running `GroupyWindowShortcuts.ps1` or manual hotkey tests

## Known Remaining Risks / Cleanup

1. `ActivityDotsRuntime.log` contains older noisy diagnostic lines and historical errors. That is okay for now, but it may be useful to rotate/trim later.
2. `live-notification` diagnostic signatures remain enabled. They are concise and change-only, but can be removed later once stability is established.
3. The live bridge uses a private VS Code extension-host inspector path. It is version-specific and may need repair after VS Code/Codex extension updates.
4. If an extension host does not expose an inspector websocket, live dots cannot attach to that window until its extension host is restarted or otherwise exposes the endpoint.
5. Manual stop/abort over the live path should be tested again. File fallback already recognizes rollout `turn_aborted`; live path recognizes `turn/aborted`, `turn/cancelled`, `turn/canceled`, `turn/failed`, and `turn/error`, but exact VS Code live abort event should be verified.
6. Orange/needs-input remains intentionally disabled unless `-EnableNeedsUserBridge` is passed. Do not work on orange until yellow/green have stayed stable.

## Do Not Regress These Constraints

- no OCR
- do not slow Groupy manual clicks
- do not slow Ctrl+1 through Ctrl+9 tab switching
- do not freeze or noticeably lag VS Code
- preserve old experiment files
- keep all-groups rendering disabled by default
- keep orange/private needs-input path disabled by default
- diagnostics must never break the render loop

