# Groupy no-dialog rename investigation

Goal: update the active Groupy tab title from the active Codex conversation without creating Groupy's visible **Rename Tab** dialog.

## Codex chat rename (Ctrl+Shift+R)

- `thread/resume` against a chat already open in VS Code fails by design: the desktop Codex app-server that owns the active task holds that thread's exclusive writer lock.
- `thread/name/set` does **not** need a resume first. Sending it directly from a short-lived local app-server updates the persisted rollout successfully, but not the already-open task owner's in-memory title. The visible title reverts, so `CodexChatRenameHotkey.ps1` is retained as an experiment rather than a daily shortcut.
- `Inspect-CodexAppServerPipes.ps1` confirmed that the live writer is the desktop Codex app-server (not a VS Code child process) and identifies its writer lock plus standard handles read-only.
- `Test-CodexLivePipeRename.ps1` successfully wrote valid JSON-RPC-shaped bytes to a duplicated live standard-input handle, but the live server did not dispatch the message. It is preserved for evidence only; do not use it for renaming.
- The Codex desktop environment's supported `set_thread_title` action updates both the actual live owner and persisted title immediately. A separate `codex app-server` process is not that live client, so its valid `thread/name/set` request only changes the persisted record.
- **VS Code extension path, identified:** the actual **Rename chat** menu action in `openai.chatgpt-26.803.61601-win32-x64` calls its private webview RPC `set-thread-title` with the active `conversationId`, `hostId`, and title. That handler immediately updates the extension's in-memory conversation title and sends the live app-server request `thread/name/set`. This is the correct behavior that the persisted-index experiment lacks.
- That private RPC is not registered as a VS Code command (the extension manifest exposes no rename command), so PowerShell and a separate companion extension cannot call it directly through VS Code's public API.
- **New live bridge:** VS Code's current extension-host Node process exposes its normal local Inspector endpoint. `CodexVsCodeLiveRenameBridge.js` uses it to locate the loaded `CodexWebviewProvider`, retrieve its initialized `CodexMcpConnection`, and invoke `thread/name/set` through that exact existing connection. A read-only `thread/list` probe and a same-title rename both returned successful responses from the actual extension-owned app-server process (PID `23440` in this session). This is the first no-click path that can deliver the name-updated event back to the open VS Code client. It remains version-sensitive and needs a visible-title test before becoming part of the daily launcher.
- `session_index.jsonl` is append-only, not one row per thread. It records each new persisted thread name as another line with the same `id`. The original rename helper incorrectly treated those revisions as duplicate chats; it now deduplicates by thread ID and retains the newest record before checking title ambiguity.
- **Known anomalous task:** thread `019febf1-11ba-7ba0-8228-cd3e2a220648` has a split title source. Its newest local session-index record is `Automate Groupy Codex tabs 2` (including a record written by the extension's own Rename action), while the reloaded live Codex view reports `Automate Groupy Codex tabs`. Because the hotkey deliberately matches only the newest unique local title, it refuses to rename this one task rather than risk targeting a different chat. Other tested VS Code-local chats rename normally through the live bridge. Treat this as a pre-existing client/local-vs-live synchronization anomaly, not a general rename-hotkey failure.

Scope: this is intentionally specific to the installed Groupy 2.3.1 build at `C:\Program Files (x86)\Stardock\Groupy2`. The current working implementation remains in `CodexGroupyTabSync.ps1`; `CodexGroupyTabSync-legacy-popup-free.ps1` is the preserved fallback.

## Working pieces

- **Per-tab Codex activity:** a local Codex rollout records explicit `task_started` and `task_complete` events. The final such lifecycle event determines a chat's normal visual state: yellow while working and green after its latest completed turn. The live VS Code app-server connection additionally emits structured server requests including `item/tool/requestUserInput`, `mcpServer/elicitation/request`, and later `serverRequest/resolved`; the activity-dot helper mirrors those non-mutating events through the already-used Node Inspector bridge and paints an orange override while a request is pending.
- **Exact activity-dot placement:** Groupy 2.3.1 stores a parallel 16-byte tab-rectangle array at group-record `+0x76E8`, aligned with the ordered tab HWNDs at `+0x7040`. `GroupyCodexActivityDots.ps1` reads those rectangles and draws one click-through transparent WPF overlay per live Groupy strip, so it does not inject into Groupy or use OCR. Each overlay is a non-topmost owned window of its stable Groupy strip: it remains above that strip across monitors but is correctly covered by another foreground app. Group-record locations are cached per strip after discovery, avoiding a 2,000-record memory scan on every visual update.
- **Manual tab-click safety:** WPF control hit-testing alone is insufficient for a transparent overlay; it can still be the native hit-test target over Groupy's strip. The activity overlay now returns `HTTRANSPARENT` for `WM_NCHITTEST`, so pointer clicks go directly to Groupy. A per-window resolved-chat cache also survives VS Code's short-lived editor-caption transitions during tab activation, preventing a completed (green) dot from blinking out.
- **Read completion semantics:** the lifecycle `task_complete` event contains its turn ID. A green dot is therefore treated as an unread completion badge per VS Code window, not a permanent terminal state: a new completion is green only if it finished while that window was unfocused, and focus clears it.
- **Lifecycle performance hardening:** PowerShell `Get-Content -Tail 4000` plus JSON parsing is unreliable for large rollout logs, and recursively resolving every session-index entry against `.codex\\sessions` can stall the WPF dispatcher for tens of seconds. The dot helper now probes only newly appended bytes using a native file reader, identifies the latest fully shaped `event_msg` lifecycle marker without parsing message text, and lazily resolves only the visible chat's rollout path with `rg` (measured at ~87 ms here). This keeps status propagation on a 250 ms tick without whole-history work.
- **Multi-group overlay outcome:** one WPF overlay per Groupy strip can visually cover multiple monitors, but even with `HTTRANSPARENT`, cached group records, and non-topmost strip ownership it destabilized Groupy's manual activation and queued `Ctrl+1`–`Ctrl+9` switches. This mode remains available as `-AllGroups` for future investigation, but the daily helper intentionally uses the previously stable single active-strip overlay.
- **Current activity-dot safety status:** the single-strip helper briefly produced stale/one-shot visuals because the update callback referenced a renamed `$owner` variable and threw on every tick. Runtime diagnostics exposed and corrected this; the regular yellow/green lifecycle path is back in `Start-CodexGroupyTools.ps1`. The optional orange approval/input path remains disabled by default because it uses VS Code's private Inspector connection and needs separate hardening.
- **Per-window Codex title detection:** Windows UI Automation exposes the selected Codex conversation header inside the relevant VS Code window. The active header matches a Button class containing `flex-1 truncate` and `text-start`.
- **Groupy rename:** Groupy's configured Rename Tab hotkey is `Ctrl + Alt + Shift + F2` (`^%+{F2}` in SendKeys).
- **Native dialog submission:** After the hotkey, the helper sets the native Edit control with `WM_SETTEXT` and presses the native OK button with `BM_CLICK`. It does not type into VS Code or use the clipboard.
- **Fastest dialog path so far:** the current script spin-polls Groupy's `#32770` dialog immediately after sending the hotkey and submits it as soon as the Edit and OK controls exist. It can sometimes close the dialog before it paints, but a compositor-frame flash still occurs intermittently.
- **True no-dialog path for fresh tabs:** a Groupy tab that has never been manually renamed follows the VS Code window caption. `SetWindowText` on such a fresh VS Code tab updates its Groupy label with no Rename Tab dialog. The script exposes this as `-WatchAutoTitle`, derives the workspace name from the first Files Explorer root item, reapplies the chat name after VS Code changes the caption for an editor-file selection, and labels the Codex home/new-chat and closed-webview states separately.

## Confirmed non-solutions

| Experiment | Result | Why it does not solve the goal |
| --- | --- | --- |
| Set the VS Code native window caption with `SetWindowText` | Worked on the VS Code caption only | Groupy retains its manually assigned tab label; its tab does not follow the host caption. |
| Clear Groupy window properties such as `GP_LCUST`, set `GP_UPDTAB`, then redraw | No visible tab change | These properties are not a usable public title-update interface. |
| Send the registered `GP_UPDTAB` message to Groupy or Code | No visible tab change | The message alone is insufficient; its required internal state/arguments remain unknown. |
| Send the distinct registered `GP_UPDTAB2` message after temporarily changing the host caption | No visible tab change | The string is present in both `GroupyCtrl.exe` and `Groupy_64.dll`, but delivery to the VS Code window and its `GP_LINK` target with zero and source-window `wParam` values returned no handler result. The host caption was restored. |
| Edit the active tab-title text found in `GroupyCtrl.exe` memory | No visible tab change | The rendered tab uses separate state or a cached model; memory was restored after testing. |
| `EVENT_OBJECT_SHOW` external event hook | Faster than manual typing, still flashes | The notification occurs only after Groupy has made the dialog visible. |
| `EVENT_OBJECT_CREATE` plus hide/zero-alpha | Still flashes | Out-of-process event delivery can arrive after Groupy has already produced a compositor frame. |
| Thread-specific in-process `WH_CBT` hook (`GroupyNoFlashHook*.dll`) | No callback received | Groupy creates each rename dialog on a newly created UI thread. There is no stable thread to hook before the hotkey. |
| Hook all currently existing GroupyCtrl and active Code threads | No callback received | Tracing confirmed the dialog's owner thread changes for each rename and no longer exists after it closes. |
| Full-screen screenshot mask | Not implemented | It would hide the popup visually but momentarily freeze the screen; deliberately rejected as a poor experience. |

## Useful observations

- Dialog class: `#32770`, owned by `GroupyCtrl.exe` (PID varies per session).
- The dialog contains an `Edit` child and an `OK` `Button` child.
- Each rename observed so far was created on a fresh GroupyCtrl UI thread (for example thread IDs `32512` and `5224`); those threads were gone after the dialog closed.
- GroupyCtrl has a `GROUPYCTRL` window and places Groupy-specific properties on grouped application windows, including `GP_LINK` and `GP_LCUST`.
- The active application window's `GP_LINK` value points at a GroupyCtrl `#32770` window, but manipulating that property did not rename the tab.
- On the active grouped VS Code window, `GP_LINK`, `GP_LIVE`, `GP_SETM`, `GP_UPDTAB`, and `GP_LCUST` are currently present (`GP_SETM` and `GP_UPDTAB` have value `1`); `GP_UPDTAB2` is absent. These look like Groupy state markers, not sufficient commands by themselves.
- `GroupySrv.exe` exposes a live named pipe at `\\.\pipe\GroupySrv`. Static inspection suggests it is primarily Groupy's service/control pipe; no title-update command is known yet.
- GroupyCtrl strings include `GroupyListen%d`, but no matching live named pipe was observed.
- Groupy 2 configuration exposes only the Rename Tab hotkey; no supported direct rename API was found.
- `GP_UPDTAB2`, `GP_SETM`, and `GROUPY_RELOAD` are also registered-message-style strings in both GroupyCtrl and its injected 64-bit DLL. `GP_UPDTAB2` has now been tested with the low-risk target/argument combinations above; it is not a standalone rename command.
- A `WH_CALLWNDPROC` trace on the stable `GP_LINK` owner thread during successful helper renames captured `GP_UPDTAB2` (`0xC2DA` in this session) to `GP_LINK`, with `wParam = active VS Code HWND`. Its nonzero `lParam` was resolved while live: it is the Windows `IME` window titled `Default IME`, not the Rename dialog or a title object. Treat `GP_UPDTAB2` as a focus/input-side signal, not a direct rename path. `GP_UPDTAB` (`0xC2CD`) is also delivered with `wParam = 1`, but has not produced a title update when invoked externally.

## Current direction: true no-dialog rename

For existing custom-named tabs, the remaining promising paths are:

1. Identify a private GroupyCtrl message/command that mutates the tab model and forces its internal redraw.
2. Recover the internal state layout around the active tab model, then find the matching model-update or redraw routine.
3. Determine whether `GroupySrv` accepts a command protocol that can reach GroupyCtrl without the Rename Tab UI.

Do not re-run the experiments in **Confirmed non-solutions** unless new evidence changes their prerequisites.

## Native Groupy tab-order investigation (in progress)

This section is separate from the title-update work. Its goal is an exact, no-OCR implementation of `Ctrl+1` through `Ctrl+9` for this fixed Groupy build.

- The visible primary-monitor tab strip is a top-level GroupyCtrl `#32770` window. Its `GP_LINK` value is also placed on each member application window.
- The tab strip has no useful UI Automation or MSAA child objects: its accessibility client reports zero children. This rules out a supported accessibility-based tab-order query.
- A read-only in-process `WH_CALLWNDPROC` diagnostic resolved the strip's real window procedure to `GroupyCtrl.exe + 0x42640`, which tail-jumps to `GroupyCtrl.exe + 0x447D0`.
- Disassembly of that procedure shows GroupyCtrl's fixed group-record table: image RVA `0x196F30`, 2,000 records, `0x7CC0` bytes per record. The procedure resolves the receiving strip to one of those records before handling mouse and tab messages.
- In the live record for the primary VS Code group (slot 783 in the current session), `+0x7BF0` is the strip HWND and `+0x7040` is a 53-entry, 64-bit HWND array. Its nonzero entries were:

  ```text
  +0x7040  0x4020C
  +0x7048  0x60058
  +0x7050  0x100C0A
  +0x7058  0x4414C8
  ```

  These are the Groupy member windows in the current displayed tab order. `+0x71E8` holds a parallel per-member value array. The remaining entries in the `+0x7040` array are zero.
- `GroupyNumberTabs.ps1` now uses this layout as its primary path. It resolves and verifies the group-record location once, then each `Ctrl+number` reads the live strip handle plus the 53-HWND array (432 bytes total). Repeated lookups measured about 0.06–0.11 ms; tab drags still take effect immediately because the array itself is reread on every key press.

### Next validation

Perform one controlled Groupy tab drag, then confirm that the `+0x7040` array changes to the new order. If it does, a native order reader can locate the record by its `+0x7BF0` strip HWND and read up to 53 nonzero HWNDs from `+0x7040`, with no OCR, caching, or focus switching.
