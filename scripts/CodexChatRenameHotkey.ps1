[CmdletBinding()]
param(
    # Print the currently selected Codex chat and the local thread it resolves to, then exit.
    [switch]$InspectCurrent,

    # Open the rename prompt once for the current Codex chat, then exit.
    [switch]$TestCurrent,

    [ValidateRange(1000, 30000)]
    [int]$TimeoutMs = 10000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing

if (-not ('CodexGroupy.ChatRenameHotkeyNativeV3' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexGroupy {
    public static class ChatRenameHotkeyNativeV3 {
        private const int MOD_CONTROL = 0x0002;
        private const int MOD_SHIFT = 0x0004;
        private const int HOTKEY_ID = 53;
        private const int VK_R = 0x52;
        private const uint WM_HOTKEY = 0x0312;
        private const uint PM_REMOVE = 0x0001;
        private const int VK_CONTROL = 0x11;
        private const int VK_SHIFT = 0x10;

        [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; public uint lPrivate; }

        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetWindowText(IntPtr hWnd, string text);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RegisterHotKey(IntPtr hWnd, int id, int modifiers, int virtualKey);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PeekMessage(out MSG message, IntPtr hWnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int virtualKey);

        public static void Register() {
            if (!RegisterHotKey(IntPtr.Zero, HOTKEY_ID, MOD_CONTROL | MOD_SHIFT, VK_R)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not register Ctrl+Shift+R. Another app is already using it.");
            }
        }
        public static void Unregister() { UnregisterHotKey(IntPtr.Zero, HOTKEY_ID); }
        public static bool TakeHotkey() {
            MSG message;
            bool hit = false;
            while (PeekMessage(out message, IntPtr.Zero, WM_HOTKEY, WM_HOTKEY, PM_REMOVE)) if (message.wParam.ToInt32() == HOTKEY_ID) hit = true;
            return hit;
        }
        public static bool ModifiersAreDown() { return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 || (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0; }
        public static int GetProcessId(IntPtr hWnd) { uint processId; GetWindowThreadProcessId(hWnd, out processId); return (int)processId; }
        public static string ReadWindowTitle(IntPtr hWnd) {
            int length = GetWindowTextLength(hWnd);
            var text = new StringBuilder(Math.Max(1, length + 1));
            GetWindowText(hWnd, text, text.Capacity);
            return text.ToString();
        }
    }
}
'@
}

$sessionIndexPath = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$renameLogPath = Join-Path $repoRoot 'work\CodexChatRenameHotkey.log'
$script:sessionIndexTicks = -1L
$script:sessionByTitle = @{}

function Write-RenameLog([string]$Message) {
    $directory = Split-Path -Path $renameLogPath -Parent
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    [IO.File]::AppendAllText($renameLogPath, ('[{0:HH:mm:ss.fff}] {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine))
}

function ConvertTo-CodexTitleKey([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $clean = ($Title -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    # Match the title watcher: Groupy only sees the capped variant for exceptionally long titles.
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 117).TrimEnd() + '...' }
    return $clean
}

function Update-CodexSessionIndex {
    if (-not (Test-Path -LiteralPath $sessionIndexPath)) { throw "Could not find the local Codex session index: $sessionIndexPath" }
    $item = Get-Item -LiteralPath $sessionIndexPath
    if ($script:sessionIndexTicks -eq $item.LastWriteTimeUtc.Ticks) { return }

    # session_index.jsonl is append-only: every title change produces another record for the
    # same thread. Keep only the final record for each ID before detecting duplicate titles.
    $latestById = @{}
    foreach ($line in Get-Content -LiteralPath $sessionIndexPath) {
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $entry.id -or -not $entry.PSObject.Properties['thread_name']) { continue }
        $latestById[[string]$entry.id] = $entry
    }

    $byTitle = @{}
    foreach ($entry in $latestById.Values) {
        $key = ConvertTo-CodexTitleKey ([string]$entry.thread_name)
        if (-not $key) { continue }
        if (-not $byTitle.ContainsKey($key)) { $byTitle[$key] = [Collections.Generic.List[object]]::new() }
        $byTitle[$key].Add($entry)
    }
    $script:sessionByTitle = $byTitle
    $script:sessionIndexTicks = $item.LastWriteTimeUtc.Ticks
}

function Resolve-CodexThreadByTitle([string]$Title) {
    Update-CodexSessionIndex
    $key = ConvertTo-CodexTitleKey $Title
    if (-not $key -or -not $script:sessionByTitle.ContainsKey($key)) { return $null }
    $matches = $script:sessionByTitle[$key]
    if ($matches.Count -ne 1) { return $null }
    $entry = $matches[0]
    return [pscustomobject]@{ ThreadId = [string]$entry.id; Title = [string]$entry.thread_name }
}

function Get-CodexTitleMatchCount([string]$Title) {
    Update-CodexSessionIndex
    $key = ConvertTo-CodexTitleKey $Title
    if (-not $key -or -not $script:sessionByTitle.ContainsKey($key)) { return 0 }
    return $script:sessionByTitle[$key].Count
}

function Get-PersistedCodexThreadName([string]$ThreadId) {
    if (-not (Test-Path -LiteralPath $sessionIndexPath)) { return $null }
    $latestName = $null
    foreach ($line in Get-Content -LiteralPath $sessionIndexPath) {
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ([string]$entry.id -eq $ThreadId -and $entry.PSObject.Properties['thread_name']) {
            $latestName = [string]$entry.thread_name
        }
    }
    return $latestName
}

function Get-CurrentCodexChat {
    $window = [CodexGroupy.ChatRenameHotkeyNativeV3]::GetForegroundWindow()
    if ($window -eq [IntPtr]::Zero) { throw 'No foreground window.' }

    $processId = [CodexGroupy.ChatRenameHotkeyNativeV3]::GetProcessId($window)
    try { $process = Get-Process -Id $processId -ErrorAction Stop } catch { throw 'The foreground window no longer belongs to a running process.' }
    if ($process.ProcessName -ne 'Code') { throw 'Focus a VS Code window with an open Codex chat first.' }

    # The auto-title helper has already placed the selected chat title in the native caption. Reading it is a
    # cheap Win32 call; it avoids a roughly one-second UIA webview traversal on the normal hotkey path.
    $nativeTitle = [CodexGroupy.ChatRenameHotkeyNativeV3]::ReadWindowTitle($window)
    $nativeMatch = Resolve-CodexThreadByTitle $nativeTitle
    if ($nativeMatch) {
        return [pscustomobject]@{ Window = $window; ThreadId = $nativeMatch.ThreadId; Title = $nativeMatch.Title }
    }

    # Fallback for a manually launched rename helper when the title-sync helper is not running.
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
        $documentCondition = [System.Windows.Automation.AndCondition]::new(@(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Document
            ),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'Codex'
            )
        ))
        $document = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $documentCondition)
        if (-not $document) { throw 'No open Codex chat was found in the focused VS Code window.' }

        $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button
        )
        $buttons = $document.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
        $title = $null
        foreach ($button in $buttons) {
            if ([string]::IsNullOrWhiteSpace($button.Current.Name)) { continue }
            if ($button.Current.ClassName -match 'flex-1\s+truncate' -and $button.Current.ClassName -match 'text-start') {
                $title = $button.Current.Name.Trim()
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($title)) { throw 'Codex is open, but no existing chat is selected (the home/new-chat screen cannot be renamed).' }
    }
    catch {
        if ($_.Exception.Message -match 'Codex is open|No open Codex|home/new-chat') { throw }
        throw "Could not read the selected Codex chat. $($_.Exception.Message)"
    }

    $match = Resolve-CodexThreadByTitle $title
    if ($match) { return [pscustomobject]@{ Window = $window; ThreadId = $match.ThreadId; Title = $match.Title } }
    if ((Get-CodexTitleMatchCount $title) -gt 1) { throw "More than one local Codex chat is named '$title'. Rename one of the duplicates once through Codex's menu, then this shortcut will be safe to use." }
    throw "Could not resolve the selected chat '$title' to a local Codex thread yet. Send one message in it, then try again."
}

function Show-RenameDialog([string]$CurrentName) {
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Rename Codex chat'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.ClientSize = [System.Drawing.Size]::new(520, 108)
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowInTaskbar = $false
    $form.TopMost = $true

    $label = [System.Windows.Forms.Label]::new()
    $label.Text = 'New chat name'
    $label.AutoSize = $true
    $label.Location = [System.Drawing.Point]::new(12, 12)

    $text = [System.Windows.Forms.TextBox]::new()
    $text.Text = $CurrentName
    $text.Location = [System.Drawing.Point]::new(12, 32)
    $text.Size = [System.Drawing.Size]::new(496, 23)

    $ok = [System.Windows.Forms.Button]::new()
    $ok.Text = 'Rename'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = [System.Drawing.Point]::new(352, 70)
    $ok.Size = [System.Drawing.Size]::new(75, 26)

    $cancel = [System.Windows.Forms.Button]::new()
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = [System.Drawing.Point]::new(433, 70)
    $cancel.Size = [System.Drawing.Size]::new(75, 26)

    [void]$form.Controls.AddRange(@($label, $text, $ok, $cancel))
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $form.Add_Shown({ $text.Focus(); $text.SelectAll() })
    $result = $form.ShowDialog()
    $name = $text.Text.Trim()
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($name)) { return $null }
    return $name
}

function Write-Rpc([System.Diagnostics.Process]$Process, [object]$Message) {
    $Process.StandardInput.WriteLine(($Message | ConvertTo-Json -Compress -Depth 10))
    $Process.StandardInput.Flush()
}

function Read-RpcResponse([System.Diagnostics.Process]$Process, [int]$Id, [int]$WaitMs) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt $WaitMs) {
        $remaining = [Math]::Max(1, $WaitMs - [int]$deadline.ElapsedMilliseconds)
        $lineTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $lineTask.Wait($remaining)) { throw "Timed out waiting for Codex app-server response $Id." }
        $line = $lineTask.Result
        if ($null -eq $line) { throw "Codex app-server exited while waiting for response $Id." }
        try { $message = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($message.PSObject.Properties['id'] -and $message.id -eq $Id) {
            if ($message.PSObject.Properties['error'] -and $message.error) { throw "Codex app-server: $($message.error.message)" }
            return $message.result
        }
    }
    throw "Timed out waiting for Codex app-server response $Id."
}

function Set-CodexThreadName([string]$ThreadId, [string]$Name) {
    try {
        Set-CodexThreadNameViaLiveVsCodeConnection -ThreadId $ThreadId -Name $Name
        return
    }
    catch {
        $liveError = $_.Exception.Message
        Write-RenameLog "Live VS Code rename unavailable for $ThreadId -> '$Name'; falling back to detached persisted update: $liveError"
        Set-CodexThreadNameViaDetachedAppServer -ThreadId $ThreadId -Name $Name
    }
}

function Get-CodexExtensionHostInspectorUrls {
    # VS Code's extension host currently runs inside its NodeService utility process.
    # Older builds exposed bootstrap-fork.js directly, but 1.131 only shows the
    # NodeService command line while retaining the local Inspector endpoint.
    $extensionHosts = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" -ErrorAction Stop |
        Where-Object {
            $_.CommandLine -match '--utility-sub-type=node\.mojom\.NodeService' -and
            $_.CommandLine -match '--inspect-port=0'
        }
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($extensionHost in $extensionHosts) {
        $listeners = Get-NetTCPConnection -OwningProcess ([int]$extensionHost.ProcessId) -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') }
        foreach ($listener in $listeners) {
            $hostPart = if ($listener.LocalAddress -eq '::1') { '[::1]' } else { '127.0.0.1' }
            try {
                $endpoint = Invoke-RestMethod -Uri ("http://{0}:{1}/json/list" -f $hostPart, $listener.LocalPort) -TimeoutSec 2 -ErrorAction Stop
                foreach ($entry in @($endpoint)) {
                    if ($entry.type -eq 'node' -and $entry.webSocketDebuggerUrl) {
                        [void]$urls.Add([string]$entry.webSocketDebuggerUrl)
                    }
                }
            }
            catch {
                # A different local service can use a VS Code extension-host listener. Ignore it.
            }
        }
    }
    return @($urls | Select-Object -Unique)
}

function Invoke-LiveRenameBridge([ValidateSet('prepare', 'rename')][string]$Operation, [string]$InspectorUrl, [string]$ThreadId, [string]$Name) {
    $node = Get-Command node -CommandType Application -ErrorAction Stop
    $bridge = Join-Path $PSScriptRoot 'CodexVsCodeLiveRenameBridge.js'
    if (-not (Test-Path -LiteralPath $bridge)) { throw "Missing live rename bridge: $bridge" }
    $arguments = @($bridge, $Operation, $InspectorUrl)
    if ($Operation -eq 'rename') { $arguments += @($ThreadId, $Name) }
    $raw = & $node.Source @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($raw | Out-String).Trim() }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "The live rename bridge returned invalid JSON: $($raw | Out-String)" }
}

$script:LiveRenameInspectorUrls = @()

function Initialize-LiveVsCodeRenameConnections {
    $prepared = [System.Collections.Generic.List[string]]::new()
    $inspectorUrls = @(Get-CodexExtensionHostInspectorUrls)
    if ($inspectorUrls.Count -eq 0) {
        Write-RenameLog 'Live rename setup found zero VS Code extension-host Inspector endpoints.'
    }
    foreach ($inspectorUrl in $inspectorUrls) {
        try {
            $result = Invoke-LiveRenameBridge -Operation prepare -InspectorUrl $inspectorUrl
            if ($result.prepared) {
                [void]$prepared.Add($inspectorUrl)
                Write-RenameLog "Prepared live VS Code Codex connection (app-server PID $($result.processId))."
            }
        }
        catch {
            Write-RenameLog "Skipped a VS Code Inspector endpoint during live-rename setup: $($_.Exception.Message)"
        }
    }
    $script:LiveRenameInspectorUrls = @($prepared | Select-Object -Unique)
    return $script:LiveRenameInspectorUrls.Count
}

function Set-CodexThreadNameViaLiveVsCodeConnection([string]$ThreadId, [string]$Name) {
    if ($script:LiveRenameInspectorUrls.Count -eq 0) {
        [void](Initialize-LiveVsCodeRenameConnections)
    }
    if ($script:LiveRenameInspectorUrls.Count -eq 0) {
        throw 'No initialized Codex VS Code extension connection was found. Open the Codex view in VS Code, then try again.'
    }

    $successes = 0
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($inspectorUrl in $script:LiveRenameInspectorUrls) {
        try {
            $result = Invoke-LiveRenameBridge -Operation rename -InspectorUrl $inspectorUrl -ThreadId $ThreadId -Name $Name
            if ($result.ok) {
                $successes++
                Write-RenameLog "Live VS Code app-server accepted thread/name/set for $ThreadId -> '$Name'."
            }
            else {
                [void]$failures.Add([string]$result.error)
            }
        }
        catch {
            [void]$failures.Add($_.Exception.Message)
        }
    }
    if ($successes -eq 0) {
        throw ("No live VS Code app-server accepted the rename. " + ($failures -join ' | '))
    }
}

function Set-CodexThreadNameViaDetachedAppServer([string]$ThreadId, [string]$Name) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # Match the process that the VS Code Codex extension itself launches. The global `codex` CLI can be a
    # different build with a separate runtime mode, which accepts the protocol but does not own this UI's state.
    $extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
    $extensionCodex = Get-ChildItem -LiteralPath $extensionRoot -Directory -Filter 'openai.chatgpt-*-win32-x64' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\windows-x86_64\codex.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ($extensionCodex) {
        $startInfo.FileName = $extensionCodex
        $startInfo.Arguments = '-c features.code_mode_host=true app-server --analytics-default-enabled'
    }
    else {
        $command = Get-Command codex -ErrorAction Stop
        if ($command.CommandType -eq 'Application' -and $command.Source -notmatch '\.ps1$') {
            $startInfo.FileName = $command.Source
            $startInfo.Arguments = 'app-server'
        }
        else {
        $npmBin = Split-Path $command.Source -Parent
        $entryPoint = Join-Path $npmBin 'node_modules\@openai\codex\bin\codex.js'
        $node = Get-Command node -CommandType Application -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $entryPoint)) { throw "Could not find Codex npm entry point: $entryPoint" }
        $startInfo.FileName = $node.Source
        $startInfo.Arguments = ('"{0}" app-server' -f $entryPoint.Replace('"', '\"'))
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start codex app-server.' }
        Write-RenameLog "Starting direct persisted-name update: thread=$ThreadId; name='$Name'; codex='$($startInfo.FileName)'"
        Write-Rpc $process @{ method = 'initialize'; id = 1; params = @{ clientInfo = @{ name = 'codex-chat-rename-hotkey'; title = 'Codex Chat Rename Hotkey'; version = '1.0.0' } } }
        Write-Rpc $process @{ method = 'initialized'; params = @{} }
        [void](Read-RpcResponse $process 1 $TimeoutMs)
        # Do not resume this chat here.  VS Code owns its live writer, so resuming from a
        # second app-server instance correctly fails with "already has an active writer".
        # `thread/name/set` also supports a persisted rollout directly, which updates the
        # stored name without competing with the VS Code-owned live thread.
        Write-Rpc $process @{ method = 'thread/name/set'; id = 2; params = @{ threadId = $ThreadId; name = $Name } }
        $result = Read-RpcResponse $process 2 $TimeoutMs
        Write-RenameLog "app-server accepted thread/name/set for $ThreadId -> '$Name'; response=$($result | ConvertTo-Json -Compress -Depth 4)"
    }
    finally {
        if ($process -and -not $process.HasExited) {
            try { $process.StandardInput.Close() } catch {}
            if (-not $process.WaitForExit(1000)) { try { $process.Kill() } catch {} }
        }
        if ($process) { $process.Dispose() }
    }
}

function Invoke-RenameCurrentCodexChat {
    $chat = Get-CurrentCodexChat
    Write-RenameLog ("Hotkey resolved foreground Code window 0x{0:X}: thread=$($chat.ThreadId); title='$($chat.Title)'" -f $chat.Window.ToInt64())
    $newName = Show-RenameDialog $chat.Title
    if ($null -eq $newName) {
        Write-RenameLog 'Rename dialog cancelled.'
        return
    }
    # PowerShell's ordinary `-eq` is case-insensitive. A casing-only cleanup is still a
    # real chat rename and should be sent to the live Codex connection.
    if ($newName -ceq $chat.Title) {
        Write-RenameLog "Rename skipped because the submitted title is unchanged: '$newName'."
        return
    }
    try {
        Set-CodexThreadName -ThreadId $chat.ThreadId -Name $newName
        # Groupy's automatic tab text follows VS Code's native caption. Set it now instead
        # of waiting for the independent title watcher to notice the webview refresh.
        if (-not [CodexGroupy.ChatRenameHotkeyNativeV3]::SetWindowText($chat.Window, $newName)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'Could not update the VS Code window title after the chat rename.')
        }
        Start-Sleep -Milliseconds 350
        $persistedName = Get-PersistedCodexThreadName $chat.ThreadId
        $captionAfter = [CodexGroupy.ChatRenameHotkeyNativeV3]::ReadWindowTitle($chat.Window)
        Write-RenameLog "Verification after 350ms: persisted='$persistedName'; native-caption='$captionAfter'."
        Write-Host "Rename request sent for Codex chat: $newName"
    }
    catch {
        Write-RenameLog "thread/name/set FAILED for $($chat.ThreadId) -> '$newName': $($_.Exception.Message)"
        throw
    }
}

if ($InspectCurrent) {
    $chat = Get-CurrentCodexChat
    [pscustomobject]@{ ActiveHwnd = ('0x{0:X}' -f $chat.Window.ToInt64()); ThreadId = $chat.ThreadId; CurrentName = $chat.Title }
    return
}

if (-not $InspectCurrent) {
    Write-Host 'Preparing the live VS Code Codex rename connection...'
    $preparedCount = Initialize-LiveVsCodeRenameConnections
    if ($preparedCount -eq 0) {
        Write-RenameLog 'No live Codex VS Code connection was prepared. Ctrl+Shift+R will use detached persisted-name fallback until a live Inspector endpoint appears.'
        Write-Warning 'No live Codex VS Code connection was prepared. Keep the Codex view open, then restart this helper.'
    }
    else {
        Write-RenameLog ("Live Codex rename is ready ({0} VS Code extension host{1})." -f $preparedCount, $(if ($preparedCount -eq 1) { '' } else { 's' }))
        Write-Host ("Live Codex rename is ready ({0} VS Code extension host{1})." -f $preparedCount, $(if ($preparedCount -eq 1) { '' } else { 's' }))
    }
}

if ($TestCurrent) {
    Invoke-RenameCurrentCodexChat
    return
}

# Do the small local-index read before the user presses the hotkey, not on its first use.
Update-CodexSessionIndex
[CodexGroupy.ChatRenameHotkeyNativeV3]::Register()
try {
    Write-Host 'Ctrl+Shift+R now opens a rename box for the selected Codex chat. Press Ctrl+C to stop.'
    while ($true) {
        if ([CodexGroupy.ChatRenameHotkeyNativeV3]::TakeHotkey()) {
            try {
                Invoke-RenameCurrentCodexChat
            }
            catch { Write-Warning $_.Exception.Message }
        }
        Start-Sleep -Milliseconds 25
    }
}
finally {
    [CodexGroupy.ChatRenameHotkeyNativeV3]::Unregister()
}
