# Codex → Groupy Tab Sync (proof of concept)

This is a lightweight, local PowerShell helper for the specific workflow of one Codex conversation per VS Code window, grouped into tabs by Groupy 2.

For a full new-machine setup guide, including Groupy settings, startup task setup, colors, hotkeys, and troubleshooting, see [`SETUP.md`](SETUP.md).

## Daily runtime: one supervisor

The normal setup is owned by `CodexGroupySupervisor.ps1`. It keeps the title watcher, Codex chat rename
hotkey, Chrome-style tab-number shortcuts, separate-group shortcut, usage/context overlay, and cached
all-groups Codex activity dots running as quiet background helpers.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-CodexGroupyTools.ps1
```

It is safe to run again: an already-running supervisor is detected and left alone. Check what is running:

```powershell
.\scripts\Start-CodexGroupyTools.ps1 -Status
```

To stop every background helper started by this setup:

```powershell
.\scripts\Stop-CodexGroupyTools.ps1
```

Install the supervisor to start automatically at Windows logon:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -InstallStartupTask
```

Remove that startup task:

```powershell
.\scripts\CodexGroupySupervisor.ps1 -UninstallStartupTask
```

## Codex chat rename: Ctrl+Shift+R

`CodexChatRenameHotkey.ps1` preserves the fast textbox and now includes a version-specific live VS Code bridge.
The bridge reaches the extension's already-running Codex app-server connection instead of starting a separate
app-server process, which is required for the open VS Code client to receive its `thread/name/updated` event.
If VS Code is not exposing a live Inspector endpoint, the helper falls back to a detached persisted-name update
and still updates the native window title immediately.

The local `session_index.jsonl` is append-only, so historical revisions of the same chat are not treated as duplicate chats by this helper. Genuine simultaneous chats with the same title are still rejected safely.

Test it once while a Codex view is open in VS Code:

```powershell
.\scripts\CodexChatRenameHotkey.ps1 -TestCurrent
```

The helper deliberately declines to rename the home/new-chat screen. It also declines when two saved chats
have the identical title, so it can never guess which duplicate should change.

## Findings from this machine

- The installed extension is `openai.chatgpt-26.803.41515-win32-x64` at `C:\Users\evanl\.vscode\extensions\openai.chatgpt-26.803.41515-win32-x64`.
- Its extension bundle uses Codex's app-server protocol (`thread/list`, `thread/read`, and `thread/name/updated`) rather than keeping a window-specific conversation title in VS Code storage.
- `C:\Users\evanl\.codex\session_index.jsonl` does keep the global list of Codex thread IDs and names, but it cannot identify which one a particular VS Code window currently has selected.
- Windows UI Automation does expose the Codex webview inside the exact `Code.exe` window. Its active conversation header is exposed as a named button, which is the primary per-window title signal. That makes UIA the most dependable per-window approach.
- Groupy 2 is installed at `C:\Program Files (x86)\Stardock\Groupy2`. The helper uses its enabled Rename Tab hotkey (`Ctrl + Alt + Shift + F2`).

## One-time Groupy setup

In **Stardock Groupy 2 Configuration**, enable the hotkey for **Rename Tab** and assign:

```text
Ctrl + Alt + Shift + F2
```

The script represents that with `^%+{F2}`. If you choose something else, pass its SendKeys equivalent to `-RenameHotkey`.

## Test the two primitives first

Open at least two VS Code windows in the same Groupy group. From PowerShell, run this command and then immediately switch to the Groupy/VS Code tab you want to rename:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\CodexGroupyTabSync.ps1 -TestRename -StartDelaySeconds 5
```

Its Groupy tab should become `TEST CODEX TAB`. This is intentionally a manual first test because it changes a visible Groupy tab label.

### Direct, no-dialog test

This version-specific test changes the underlying VS Code window caption, rather than invoking Groupy's Rename Tab action:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -TestNativeTitle -TestTitle 'DIRECT TITLE TEST' -StartDelaySeconds 5
```

On this machine, Groupy does change a fresh tab to `DIRECT TITLE TEST` without showing the rename dialog. It only works for tabs that have never been manually renamed; a manually renamed Groupy tab is marked custom and stops following the application caption.

Next, open an existing Codex conversation (not the blank Codex home/new-chat screen) and run:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -Inspect
```

Expected output includes each VS Code window's HWND, process, workspace label, and selected conversation title. If `CodexConversationTitle` is empty, keep the Codex conversation open and run the command again; the script deliberately refuses to guess on the home screen.

## Start synchronization: preferred no-dialog mode

For each manually renamed VS Code tab you want to migrate, close that window/tab and open a fresh VS Code window. Let Groupy group it normally, but do **not** use Groupy's Rename Tab command. Once an existing Codex chat is open in that window, run:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -WatchAutoTitle
```

This writes the selected Codex conversation name directly to the foreground VS Code window caption. Groupy sees that normal caption change and updates its own tab, with no Rename Tab dialog. A selected conversation is shown as its clean chat title alone. The watcher reapplies the caption if VS Code later replaces it while you switch editor files.

When you navigate to Codex's home/new-chat screen or close the Codex webview, the tab falls back to the plain workspace/project directory label. If the workspace cannot be resolved, the helper falls back to `Codex home` or `Codex closed`; customize either fallback label if you like:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -WatchAutoTitle -CodexHomeTitle 'Codex: choose a chat' -CodexClosedTitle 'VS Code'
```

## Chrome-style Ctrl+1 through Ctrl+9 for the current Groupy / VS Code group

Keep `-WatchAutoTitle` running, then open a **second** PowerShell window in this folder and run:

```powershell
.\scripts\GroupyNumberTabs.ps1
```

It registers global `Ctrl+1` through `Ctrl+9`, but only consumes them while a Groupy-grouped VS Code window is focused. Outside VS Code, it temporarily releases the registration and passes the original `Ctrl+number` chord through to the foreground app, so browser tab shortcuts still work. While a Groupy-grouped VS Code window is focused, those shortcuts select the first through ninth visible Groupy tab, respectively. It does not use `Ctrl+Tab`, a cached order, or OCR on its normal path. For this installed Groupy 2.3.1 build, it reads GroupyCtrl's live ordered HWND array directly, then focuses the window at that current left-to-right position. Therefore manually dragging tabs into a new order is read directly from Groupy.

Before starting the background helper, you can verify what it currently sees (with any target VS Code tab focused):

```powershell
.\scripts\GroupyNumberTabs.ps1 -Inspect
```

Example output:

```text
Tab Handle   Title
--- ------   -----
  1 0x4020C  Draft OTA stage release UI
  2 0x60058  Automate Groupy Codex tabs
  3 0x100C0A Find Codex weekly usage
```

This is intentionally scoped to the installed Groupy 2.3.1 layout. Stop the helper with `Ctrl+C` in its own PowerShell window. The legacy OCR fallback remains in the script only for resilience if GroupyCtrl cannot be read; it is not used in the normal verified path.

## Start synchronization: legacy rename-dialog mode

For an already manually named Groupy tab, use this fallback:

```powershell
.\scripts\CodexGroupyTabSync.ps1 -Watch
```

## Fallback and investigation notes

`CodexGroupyTabSync-legacy-popup-free.ps1` is a byte-for-byte fallback copy of the earlier working helper. The main helper's legacy path uses immediate native spin-polling after the Rename Tab hotkey; it is the fastest reliable dialog-based route found so far.

The optional `-UseInProcessNoFlashHook` experiment did not intercept Groupy's dialog because Groupy creates that dialog on a fresh UI thread each time. Do not use that switch. Progress toward the true no-dialog route is recorded in `docs\REVERSE_ENGINEERING_LOG.md`.

To revert to the earlier helper, stop the watcher with `Ctrl+C` and run:

```powershell
.\archive\experiments\CodexGroupyTabSync-legacy-popup-free.ps1 -Watch
```

The helper checks only the foreground `Code.exe` window ten times per second. It never activates or cycles inactive VS Code windows.

Use `Ctrl+C` to stop it. To start it at logon later, create a shortcut whose target is:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\evanl\Documents\groupy-vscode-codex-tabs\scripts\CodexGroupyTabSync.ps1" -WatchAutoTitle
```

## Safety and behavior notes

- The script uses Groupy's configured Rename Tab command but directly updates its native dialog controls; it does not type into VS Code or alter the clipboard. Newlines/tabs collapse to spaces and titles are capped at 120 characters.
- The helper begins native polling as soon as it sends Groupy's Rename Tab hotkey. It hides and submits the native dialog as soon as its Edit and OK controls are created; it can sometimes finish before the dialog paints, but Groupy can still win a compositor frame.
- `-WatchAutoTitle` does not send the Groupy hotkey. It requires a fresh, non-custom Groupy tab that is configured to follow its application window title.
- The script is intentionally not a general Groupy controller and does not touch inactive tabs.
- Codex and its VS Code extension update frequently. If a future extension changes its accessibility markup, run `-Inspect` first and adjust `Get-CodexActiveTitle` rather than attempting to infer selection from the global `.codex` database.

## Secondary workflow: new Code window

The VS Code CLI on this machine is:

```text
C:\Users\evanl\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd
```

To open the current project in another window without copying files:

```powershell
& 'C:\Users\evanl\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd' -n 'C:\path\to\your\workspace'
```

Once Groupy applies its normal grouping rule, the sync helper will name the new tab as soon as an existing Codex chat is selected in it.

## Codex weekly-usage helper

`Get-CodexUsage.ps1` starts a short-lived local `codex app-server` process, uses its JSON-RPC
`account/rateLimits/read` method, then shuts the process down. It does not touch a Codex chat,
scrape the UI, read cookies, or handle access tokens itself; the Codex client uses its normal saved
login.

Run it from any PowerShell window:

```powershell
.\scripts\Get-CodexUsage.ps1
```

The output is a PowerShell object, so it is easy to use in a widget or another script:

```powershell
$usage = .\scripts\Get-CodexUsage.ps1
"Weekly Codex usage: $($usage.WeeklyLimit); $($usage.Reset)"
```

It selects the returned 10,080-minute (seven-day) bucket with the canonical `limitId` of `codex`,
which is the quota that Codex `/status` displays. This works whether or not the account also has a
5-hour bucket; it also avoids choosing an unrelated additional Codex bucket when one is returned.
Every run closes stdin, waits briefly for the child app-server to exit, and kills only that child if
it does not exit cleanly. Repeated runs do not leave initialized servers or connections behind.

## Live weekly-usage badge on the Groupy strip

`GroupyUsageOverlay.ps1` adds a small, click-through badge to the right side of the active Groupy
tab strip while a grouped VS Code window is focused. It does not inject into Groupy, change tab
names, or intercept mouse/keyboard input. It reads the same local app-server usage value as
`Get-CodexUsage.ps1`, then refreshes it once a minute by default.

Open a separate Windows PowerShell window in this folder and run:

```powershell
.\scripts\GroupyUsageOverlay.ps1
```

Expected badge text is similar to `Codex ● 3  ● 1  ● 2      Context 78% left  |  Weekly 91%  ·  6d`.
The white dot count is all visible/resolved Codex tabs with no current activity, the yellow count is
running turns, and the green count is unread completed turns waiting for you across all visible VS Code
Groupy windows. `Context` is the active chat's
model-context percentage remaining (so higher is better); the final weekly value is the rounded-up
number of days until renewal. The overlay uses normal-weight `Segoe UI` text in `#dcdcdc` to remain
subtle against the Groupy strip, with yellow/green status counts matching the activity dots.
The badge is transparent except for its white text, so
it visually reads as part of the tab strip. It automatically hides whenever the
foreground window is not a Groupy-linked VS Code window. It also listens for Windows' native
move/resize start and end events, so it hides during a VS Code window drag and reappears when the
drag ends instead of trying to chase the moving strip. Stop it with `Ctrl+C` in that PowerShell
window. To use a different refresh interval or move the badge farther left for a little more visual padding:

```powershell
.\scripts\GroupyUsageOverlay.ps1 -RefreshSeconds 60 -RightMarginPixels 140
```

For a short visual test that exits by itself:

```powershell
.\scripts\GroupyUsageOverlay.ps1 -TestSeconds 5
```

## Codex activity dots

`GroupyCodexActivityDots.ps1` adds a tiny click-through dot to the right side of every tab in the active
Groupy strip that resolves to a Codex chat. Yellow gently pulses while its latest Codex turn is currently running; orange means
Codex has sent a live, structured request for user input, an approval, or an MCP elicitation; green means
an unread completed turn. Focusing that exact VS Code window acknowledges the completion and clears its
green dot. Tabs with no resolvable Codex chat receive no dot. The helper reads local
`task_started`/`task_complete` events plus VS Code's existing live Codex app-server connection for pending
requests, then uses Groupy's live tab rectangles. It does not use OCR or interfere with tab clicks or drags.
The default uses one click-through topmost layer only while VS Code owns the foreground, and hides while
a Groupy group is being moved. A retained `-AllGroups` experiment draws across monitors, but it is not
part of the daily launcher because multi-group overlays currently interfere with Groupy's tab activation.

The daily launcher starts the hardened yellow/green activity-dot helper automatically. The optional
orange approval/input detection remains disabled while its separate Inspector-based path is investigated.
To inspect the raw Groupy-to-Codex mapping:

```powershell
.\scripts\GroupyCodexActivityDots.ps1 -Inspect
```

### Context reading details

The context value does not send `/status` or scrape a visible status panel. The overlay first uses the
chat title that `-WatchAutoTitle` places into the VS Code caption. If VS Code temporarily replaces that
caption with an editor-file title, it falls back to the selected Codex header exposed through Windows
UI Automation. It uses the resulting title to find exactly one matching entry in the local Codex session
index, then reads only the newest `token_count` record in that chat's local rollout log. The record
carries the actual last-token count and the active model's context-window size. It refreshes every two
seconds while that VS Code tab is active. A native Windows foreground-change event also triggers an
immediate cached-label swap whenever Groupy switches to another VS Code tab. A background pass warms
the cache for the other VS Code windows in that current Groupy group every four seconds. It keys cache
entries by each window's HWND, not tab position, so manual Groupy tab reordering does not affect it.

If the Codex view is on Home/closed, the caption does not identify a chat, or two local chats have the
same title, the `ctx` value is intentionally hidden rather than risking a wrong value.
