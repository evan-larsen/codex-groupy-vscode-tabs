[CmdletBinding()]
param(
    # Exit automatically after a short visual check instead of remaining in the background.
    [ValidateRange(0, 3600)]
    [int]$TestSeconds = 0,

    [ValidateRange(4, 14)]
    [int]$DotDiameterPixels = 7,

    [ValidateRange(3, 40)]
    [int]$DotRightPaddingPixels = 9,

    # Experimental: draw separate layers over every visible Groupy group. This is retained for
    # research, but the default uses the proven single active-strip layer for zero tab-switch cost.
    [switch]$AllGroups,

    # Safer all-groups mode: cache visible Groupy strips and keep drag-time work at zero.
    # This is the intended replacement for the original poll-heavy -AllGroups experiment.
    [switch]$AllGroupsCached,

    # Opt-in only: observes VS Code's private Node Inspector connection for approval/input prompts.
    # Orange/needs-input still does not run unless this is explicitly passed.
    [switch]$EnableNeedsUserBridge,

    # Fallback switch for diagnostics. By default yellow/green use the live VS Code Codex
    # app-server connection because rollout JSONL writes are delayed during long-running turns.
    [switch]$DisableLiveLifecycleBridge,

    # Prints the raw Groupy-to-Codex activity mapping and exits; useful for diagnosis.
    [switch]$Inspect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this helper with Windows PowerShell (powershell.exe), which uses STA for its transparent dot overlay.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not ('CodexGroupy.ActivityDotsNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexGroupy {
    public static class ActivityDotsNativeV1 {
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;
        // Reverse-engineered Groupy 2.3.1 group-record layout. Read-only.
        private const int GroupCount = 0x7D0;
        private const int GroupRecordSize = 0x7CC0;
        private const int GroupTableRva = 0x196F30;
        private const int StripHandleOffset = 0x7BF0;
        private const int OrderedTabHandlesOffset = 0x7040;
        private const int OrderedTabRectanglesOffset = 0x76E8;
        private const int OrderedTabCapacity = 53;

        private const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A;
        private const uint EVENT_SYSTEM_MOVESIZEEND = 0x000B;
        private const uint WINEVENT_OUTOFCONTEXT = 0;

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
        public struct TabInfo { public long Handle; public RECT Rect; }
        public delegate void WinEventDelegate(IntPtr hook, uint eventType, IntPtr hWnd, int objectId, int childId, uint eventThread, uint eventTime);

        private static readonly ConcurrentDictionary<IntPtr, byte> MovingCodeWindows = new ConcurrentDictionary<IntPtr, byte>();
        private static readonly ConcurrentDictionary<uint, string> ProcessNameById = new ConcurrentDictionary<uint, string>();
        // A strip remains assigned to its group record for its lifetime. Caching that record turns
        // the hot path from a 2,000-record scan into just the handful of reads for its live tabs.
        private static readonly ConcurrentDictionary<IntPtr, long> GroupRecords = new ConcurrentDictionary<IntPtr, long>();
        private static readonly WinEventDelegate MoveSizeCallback = OnMoveSizeEvent;

        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        private delegate bool EnumWindowsDelegate(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumWindowsDelegate callback, IntPtr lParam);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr hWnd, string lpString);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventDelegate callback, uint processId, uint threadId, uint flags);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, IntPtr size, out IntPtr bytesRead);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);

        public static bool IsCodeWindow(IntPtr hWnd) {
            uint processId; GetWindowThreadProcessId(hWnd, out processId);
            try {
                string name = ProcessNameById.GetOrAdd(processId, id => Process.GetProcessById((int)id).ProcessName);
                return name.Equals("Code", StringComparison.OrdinalIgnoreCase) || name.Equals("Code - Insiders", StringComparison.OrdinalIgnoreCase);
            } catch { return false; }
        }
        public static string ReadWindowTitle(IntPtr hWnd) {
            int length = GetWindowTextLength(hWnd);
            if (length <= 0) return String.Empty;
            var text = new StringBuilder(length + 1);
            GetWindowText(hWnd, text, text.Capacity);
            return text.ToString();
        }
        private static IntPtr ResolveMoveTarget(IntPtr hWnd) {
            if (IsCodeWindow(hWnd)) return hWnd;
            IntPtr foreground = GetForegroundWindow();
            if (IsCodeWindow(foreground) && GetProp(foreground, "GP_LINK") == hWnd) return foreground;
            return IntPtr.Zero;
        }
        private static void OnMoveSizeEvent(IntPtr hook, uint eventType, IntPtr hWnd, int objectId, int childId, uint eventThread, uint eventTime) {
            IntPtr code = ResolveMoveTarget(hWnd);
            if (code == IntPtr.Zero) return;
            if (eventType == EVENT_SYSTEM_MOVESIZESTART) MovingCodeWindows[code] = 0;
            else if (eventType == EVENT_SYSTEM_MOVESIZEEND) { byte ignored; MovingCodeWindows.TryRemove(code, out ignored); }
        }
        public static IntPtr StartMoveSizeHook() {
            return SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND, IntPtr.Zero, MoveSizeCallback, 0, 0, WINEVENT_OUTOFCONTEXT);
        }
        public static bool IsAnyMoveSizeActive() { return !MovingCodeWindows.IsEmpty; }
        public static bool IsMoveSizeActive(IntPtr hWnd) { return MovingCodeWindows.ContainsKey(hWnd); }
        public static IntPtr[] GetCodeGroupStrips() {
            var strips = new HashSet<IntPtr>();
            EnumWindows((hWnd, lParam) => {
                if (!IsCodeWindow(hWnd)) return true;
                IntPtr strip = GetProp(hWnd, "GP_LINK");
                if (strip != IntPtr.Zero) strips.Add(strip);
                return true;
            }, IntPtr.Zero);
            var result = new IntPtr[strips.Count];
            strips.CopyTo(result);
            return result;
        }

        private static bool ReadExact(IntPtr process, long address, byte[] buffer) {
            IntPtr read;
            return ReadProcessMemory(process, new IntPtr(address), buffer, new IntPtr(buffer.Length), out read) && read.ToInt64() == buffer.Length;
        }
        private static long ReadInt64(IntPtr process, long address) {
            byte[] buffer = new byte[8];
            if (!ReadExact(process, address, buffer)) throw new InvalidOperationException("ReadProcessMemory failed while locating the Groupy tab record.");
            return BitConverter.ToInt64(buffer, 0);
        }
        private static TabInfo[] ReadTabsAtRecord(IntPtr process, long record) {
            var tabs = new List<TabInfo>();
            for (int member = 0; member < OrderedTabCapacity; member++) {
                long handle = ReadInt64(process, record + OrderedTabHandlesOffset + ((long)member * 8));
                if (handle == 0) continue;
                byte[] rawRect = new byte[16];
                if (!ReadExact(process, record + OrderedTabRectanglesOffset + ((long)member * 16), rawRect)) continue;
                var rect = new RECT {
                    Left = BitConverter.ToInt32(rawRect, 0), Top = BitConverter.ToInt32(rawRect, 4),
                    Right = BitConverter.ToInt32(rawRect, 8), Bottom = BitConverter.ToInt32(rawRect, 12)
                };
                if (rect.Right > rect.Left && rect.Bottom > rect.Top) tabs.Add(new TabInfo { Handle = handle, Rect = rect });
            }
            return tabs.ToArray();
        }
        private static bool HasLiveMembers(TabInfo[] tabs, IntPtr strip) {
            // A Groupy group record can outlive a member-window recreation. The strip handle
            // alone is therefore not enough to validate a cached record: every remembered tab
            // must still be a live window linked to this exact strip.
            if (tabs == null || tabs.Length == 0) return false;
            for (int index = 0; index < tabs.Length; index++) {
                IntPtr tab = new IntPtr(tabs[index].Handle);
                if (!IsWindow(tab) || GetProp(tab, "GP_LINK") != strip) return false;
            }
            return true;
        }
        public static TabInfo[] ReadTabs(uint groupyPid, long moduleBase, IntPtr strip) {
            IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, groupyPid);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read GroupyCtrl.exe.");
            try {
                long cachedRecord;
                if (GroupRecords.TryGetValue(strip, out cachedRecord)) {
                    if (ReadInt64(process, cachedRecord + StripHandleOffset) == strip.ToInt64()) {
                        TabInfo[] cachedTabs = ReadTabsAtRecord(process, cachedRecord);
                        if (HasLiveMembers(cachedTabs, strip)) return cachedTabs;
                    }
                    long removed; GroupRecords.TryRemove(strip, out removed);
                }
                long table = moduleBase + GroupTableRva;
                for (int group = 0; group < GroupCount; group++) {
                    long record = table + ((long)group * GroupRecordSize);
                    if (ReadInt64(process, record + StripHandleOffset) != strip.ToInt64()) continue;
                    TabInfo[] tabs = ReadTabsAtRecord(process, record);
                    if (!HasLiveMembers(tabs, strip)) continue;
                    GroupRecords[strip] = record;
                    return tabs;
                }
                return new TabInfo[0];
            } finally { CloseHandle(process); }
        }
    }
}
'@
}

if (-not ('CodexGroupy.ActivityBridgeProcessV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace CodexGroupy {
    public sealed class ActivityBridgeProcessV1 : IDisposable {
        private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
        private readonly Process process;

        private static string Quote(string value) {
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }
        public ActivityBridgeProcessV1(string nodePath, string bridgePath, string inspectorUrl, string operation) {
            var startInfo = new ProcessStartInfo {
                FileName = nodePath,
                Arguments = Quote(bridgePath) + " " + operation + " " + Quote(inspectorUrl) + " --parent-pid " + Process.GetCurrentProcess().Id,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            process.OutputDataReceived += (sender, args) => { if (!String.IsNullOrWhiteSpace(args.Data)) lines.Enqueue(args.Data); };
            process.ErrorDataReceived += (sender, args) => { if (!String.IsNullOrWhiteSpace(args.Data)) lines.Enqueue("# bridge-error: " + args.Data); };
            if (!process.Start()) throw new InvalidOperationException("Could not start the live Codex activity bridge.");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        public bool HasExited { get { return process.HasExited; } }
        public string[] Drain() {
            var result = new System.Collections.Generic.List<string>();
            string line;
            while (lines.TryDequeue(out line)) result.Add(line);
            return result.ToArray();
        }
        public void Stop() { if (!process.HasExited) process.Kill(); }
        public void Dispose() { process.Dispose(); }
    }
}
'@
}

if (-not ('CodexGroupy.ActivityLogProbeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

namespace CodexGroupy {
    public sealed class ActivityLogProbeResult {
        public long Length;
        public string State;
        public long Token;
    }
    public static class ActivityLogProbeV1 {
        // Include the enclosing event shape so quoted lifecycle strings in a user/agent message
        // cannot be mistaken for a real state transition.
        private static readonly byte[] Started = System.Text.Encoding.ASCII.GetBytes("\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"");
        private static readonly byte[] Completed = System.Text.Encoding.ASCII.GetBytes("\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"");
        // Interrupting a Codex turn does not emit task_complete. It emits this terminal event,
        // which must clear yellow rather than leaving the old working state visible.
        private static readonly byte[] Aborted = System.Text.Encoding.ASCII.GetBytes("\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"");
        private const int BlockSize = 65536;

        private static bool Matches(byte[] data, int start, int count, int index, byte[] needle) {
            if (index + needle.Length > count) return false;
            for (int n = 0; n < needle.Length; n++) if (data[index + n] != needle[n]) return false;
            return true;
        }
        private static long FindLastInBlock(byte[] data, int count, long absoluteStart, out string state) {
            state = null;
            for (int i = count - 1; i >= 0; i--) {
                if (Matches(data, 0, count, i, Started)) { state = "working"; return absoluteStart + i; }
                if (Matches(data, 0, count, i, Completed)) { state = "finished"; return absoluteStart + i; }
                if (Matches(data, 0, count, i, Aborted)) { state = "stopped"; return absoluteStart + i; }
            }
            return -1;
        }
        private static long FindLastInTail(FileStream stream, long length, long stopAt, out string state) {
            state = null;
            byte[] buffer = new byte[BlockSize + 64];
            long end = length;
            int overlap = Math.Max(Math.Max(Started.Length, Completed.Length), Aborted.Length) - 1;
            while (end > stopAt) {
                long start = Math.Max(stopAt, end - BlockSize - overlap);
                int wanted = (int)(end - start);
                stream.Seek(start, SeekOrigin.Begin);
                int received = 0;
                while (received < wanted) {
                    int read = stream.Read(buffer, received, wanted - received);
                    if (read == 0) break;
                    received += read;
                }
                long found = FindLastInBlock(buffer, received, start, out state);
                if (found >= 0) return found;
                // Once the remaining range is only the overlap, there is no earlier byte range
                // left to inspect. Continuing would assign end to the same value forever and
                // freeze the WPF dispatcher after an ordinary non-lifecycle rollout append.
                long nextEnd = start + overlap;
                if (nextEnd >= end) break;
                end = nextEnd;
            }
            return -1;
        }
        public static ActivityLogProbeResult Probe(string path, long previousLength, string previousState, long previousToken) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                long length = stream.Length;
                if (previousLength == length) return new ActivityLogProbeResult { Length = length, State = previousState, Token = previousToken };
                // On first observation, scan backward only until the newest lifecycle marker. On
                // later updates, scan only newly appended bytes (plus a tiny overlap for a split token).
                long stopAt = (previousLength >= 0 && previousLength <= length) ? Math.Max(0, previousLength - 64) : 0;
                string state;
                long token = FindLastInTail(stream, length, stopAt, out state);
                if (token < 0) return new ActivityLogProbeResult { Length = length, State = previousState, Token = previousToken };
                return new ActivityLogProbeResult { Length = length, State = state, Token = token };
            }
        }
    }
}
'@
}

$sessionIndexPath = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
$sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'

function Resolve-RipgrepPath {
    # The logon task does not inherit VS Code's extension PATH.  Prefer a PATH copy for
    # development, but locate the extension-bundled binary directly for unattended startup.
    $command = Get-Command rg.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        $command = Get-Command rg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($command) { return $command.Source }

    $extensionsRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
    if (Test-Path -LiteralPath $extensionsRoot) {
        $extensions = @(Get-ChildItem -LiteralPath $extensionsRoot -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)
        foreach ($extension in $extensions) {
            $bundled = Get-ChildItem -LiteralPath (Join-Path $extension.FullName 'bin') -Recurse -File -Filter 'rg.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($bundled) { return $bundled.FullName }
        }
    }

    throw 'Could not find rg.exe. Install or reload the ChatGPT/Codex VS Code extension, then restart the Codex/Groupy supervisor.'
}

$script:rgPath = Resolve-RipgrepPath
$script:sessionIndexTicks = -1L
$script:logByTitle = @{}
$script:logPathByThreadId = @{}
$script:nextLogLookupAt = @{}
$script:activityByLog = @{}
$script:chatByWindow = @{}
$script:displayActivityByWindow = @{}
$script:latestLifecycleByWindow = @{}
$script:groupyController = $null
$script:overlaysByStrip = @{}
$script:activityBridges = @{}
$script:liveActivityByThread = @{}
$script:pendingRequestsByKey = @{}
$script:liveNotificationSignatures = @{}
$script:lastActivityBridgeDiscoveryAt = [DateTime]::MinValue
$script:lastFullInspectorDiscoveryAt = [DateTime]::MinValue
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$script:activityDiagnosticsPath = Join-Path $repoRoot 'work\ActivityDotsRuntime.log'
$script:inspectorCachePath = Join-Path $repoRoot 'work\CodexInspectorUrl.txt'
$script:activitySummaryPath = Join-Path $repoRoot 'work\ActivityDotsSummary.json'
$script:lastDiagnosticsSignature = $null
$script:lastBridgeDiscoverySignature = $null
$script:lastHeartbeatAt = [DateTime]::MinValue
$script:helperStartedAt = Get-Date
$script:cachedGroupStrips = @()
$script:cachedGroupStripsSignature = ''
$script:lastGroupStripDiscoveryAt = [DateTime]::MinValue
$script:allGroupsLastStatsSignature = $null
$script:dirtyActivityStrips = @{}
$script:stripKeysByThread = @{}
$script:unmappedWorkingRetryUntil = [DateTime]::MinValue
$script:nextUnmappedWorkingRetryAt = [DateTime]::MinValue
$script:lastForegroundHandleRaw = 0L
$script:sessionFileWatcher = $null
$script:sessionFileWatcherSubscriptions = @()
$script:sessionFileWatcherSourcePrefix = "CodexActivityDotsSessionFile:$PID"
$script:sessionFileDirty = $false
$script:lastSessionFileEventAt = [DateTime]::MinValue
$script:lastSessionFileRenderAt = [DateTime]::MinValue
$script:lastSessionWatcherDiagnostic = $null
$script:lastMoveActive = $false
$script:workingPulseIndex = 0
$script:workingPulseOpacities = @(0.56, 0.58, 0.61, 0.65, 0.70, 0.76, 0.82, 0.88, 0.93, 0.97, 0.995, 1.0, 0.995, 0.97, 0.93, 0.88, 0.82, 0.76, 0.70, 0.65, 0.61, 0.58)
$script:activitySummaryByStrip = @{}
$script:lastActivitySummaryJson = ''

function Write-ActivityDiagnostic([string]$Message) {
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
        [System.IO.File]::AppendAllText($script:activityDiagnosticsPath, $line + [Environment]::NewLine)
    }
    catch {
        # Diagnostics must never affect Groupy/VS Code behavior.
    }
}

function Publish-ActivitySummary {
    $foreground = [CodexGroupy.ActivityDotsNativeV1]::GetForegroundWindow()
    $activeStrip = if ([CodexGroupy.ActivityDotsNativeV1]::IsCodeWindow($foreground)) {
        [CodexGroupy.ActivityDotsNativeV1]::GetProp($foreground, 'GP_LINK')
    } else {
        [IntPtr]::Zero
    }
    $activeStripKey = if ($activeStrip -eq [IntPtr]::Zero) { '' } else { $activeStrip.ToInt64().ToString('X') }
    $active = if ($activeStripKey -and $script:activitySummaryByStrip.ContainsKey($activeStripKey)) {
        $script:activitySummaryByStrip[$activeStripKey]
    } else {
        @{ idle = 0; working = 0; finished = 0 }
    }
    $all = @{ idle = 0; working = 0; finished = 0 }
    foreach ($summary in @($script:activitySummaryByStrip.Values)) {
        $all.idle += [int]$summary.idle
        $all.working += [int]$summary.working
        $all.finished += [int]$summary.finished
    }
    $payload = [ordered]@{
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        activeStrip = [ordered]@{
            key = $activeStripKey
            idle = [int]$active.idle
            working = [int]$active.working
            finished = [int]$active.finished
        }
        allVisible = [ordered]@{
            idle = [int]$all.idle
            working = [int]$all.working
            finished = [int]$all.finished
        }
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 4
    if ($json -eq $script:lastActivitySummaryJson) { return }
    $script:lastActivitySummaryJson = $json
    try {
        $tmp = "$script:activitySummaryPath.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        Move-Item -LiteralPath $tmp -Destination $script:activitySummaryPath -Force
    }
    catch {
        Write-ActivityDiagnostic "summary-write-failed $($_.Exception.Message)"
    }
}

function Start-ActivitySessionFileWatcher {
    if (-not $AllGroupsCached) { return }
    if ($script:sessionFileWatcher) { return }
    if (-not (Test-Path -LiteralPath $sessionsRoot)) { return }
    try {
        $watcher = [System.IO.FileSystemWatcher]::new($sessionsRoot, '*.jsonl')
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
        $script:sessionFileWatcherSubscriptions = @(
            Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier "$($script:sessionFileWatcherSourcePrefix):Changed"
            Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier "$($script:sessionFileWatcherSourcePrefix):Created"
            Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier "$($script:sessionFileWatcherSourcePrefix):Renamed"
        )
        $watcher.EnableRaisingEvents = $true
        $script:sessionFileWatcher = $watcher
        Write-ActivityDiagnostic "session-watcher enabled root=$sessionsRoot"
    }
    catch {
        $signature = $_.Exception.Message
        if ($signature -ne $script:lastSessionWatcherDiagnostic) {
            $script:lastSessionWatcherDiagnostic = $signature
            Write-ActivityDiagnostic "session-watcher unavailable: $signature"
        }
    }
}

function Update-SessionFileDirtyState {
    if (-not $AllGroupsCached) { return }
    if (Test-LiveLifecycleBridgeReady) { return }
    Start-ActivitySessionFileWatcher
    $events = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$($script:sessionFileWatcherSourcePrefix):*" })
    if ($events.Count -gt 0) {
        foreach ($event in $events) {
            try { Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue } catch {}
        }
        $script:sessionFileDirty = $true
        $script:lastSessionFileEventAt = Get-Date
    }
    if (-not $script:sessionFileDirty) { return }
    $now = Get-Date
    if (($now - $script:lastSessionFileEventAt).TotalMilliseconds -lt 150) { return }
    if (($now - $script:lastSessionFileRenderAt).TotalMilliseconds -lt 1500) { return }
    $script:sessionFileDirty = $false
    $script:lastSessionFileRenderAt = $now
    Set-AllActivityStripsDirty 'session-file'
}

function ConvertTo-CodexTitleKey([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $clean = ($Title -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 117).TrimEnd() + '...' }
    return $clean
}

function Update-CodexSessionMap {
    if (-not (Test-Path -LiteralPath $sessionIndexPath)) { return }
    $indexItem = Get-Item -LiteralPath $sessionIndexPath
    if ($script:sessionIndexTicks -eq $indexItem.LastWriteTimeUtc.Ticks) { return }

    $latestById = @{}
    foreach ($line in Get-Content -LiteralPath $sessionIndexPath) {
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $entry.id -or -not $entry.PSObject.Properties['thread_name']) { continue }
        $latestById[[string]$entry.id] = $entry
    }

    $candidatesByTitle = @{}
    foreach ($entry in $latestById.Values) {
        $title = ConvertTo-CodexTitleKey ([string]$entry.thread_name)
        if (-not $title) { continue }
        if (-not $candidatesByTitle.ContainsKey($title)) { $candidatesByTitle[$title] = [Collections.Generic.List[object]]::new() }
        $candidatesByTitle[$title].Add($entry)
    }

    $previous = $script:logByTitle
    $resolved = @{}
    foreach ($title in $candidatesByTitle.Keys) {
        $candidates = $candidatesByTitle[$title]
        if ($candidates.Count -ne 1) { continue }
        $id = [string]$candidates[0].id
        # Do not recursively search the session tree for every indexed chat here. On a large
        # history that turns a tiny session-index update into minutes of synchronous filesystem
        # work. The specific visible window resolves its one log lazily below.
        $knownPath = if ($script:logPathByThreadId.ContainsKey($id)) { $script:logPathByThreadId[$id] } elseif ($previous.ContainsKey($title) -and $previous[$title].ThreadId -eq $id) { $previous[$title].LogPath } else { $null }
        $resolved[$title] = [pscustomobject]@{ ThreadId = $id; LogPath = $knownPath }
    }
    $script:logByTitle = $resolved
    $script:sessionIndexTicks = $indexItem.LastWriteTimeUtc.Ticks
}

function Resolve-CodexSessionLogPath([string]$ThreadId) {
    if (-not $ThreadId) { return $null }
    if ($script:logPathByThreadId.ContainsKey($ThreadId)) { return $script:logPathByThreadId[$ThreadId] }
    $now = Get-Date
    if ($script:nextLogLookupAt.ContainsKey($ThreadId) -and $script:nextLogLookupAt[$ThreadId] -gt $now) { return $null }
    try {
        # rg's native file walker finds one known rollout filename in milliseconds; PowerShell's
        # recursive provider enumeration is dramatically slower on a long Codex session history.
        $path = @(& $script:rgPath --files $sessionsRoot -g "*$ThreadId.jsonl" 2>$null | Select-Object -First 1)[0]
        if ($path -and (Test-Path -LiteralPath $path)) {
            $script:logPathByThreadId[$ThreadId] = $path
            return $path
        }
    }
    finally {
        # A newly created rollout may not be flushed to disk yet. Retry it occasionally, never on
        # every 350 ms visual tick.
        $script:nextLogLookupAt[$ThreadId] = $now.AddSeconds(5)
    }
    return $null
}

function Get-ActivityState([string]$LogPath) {
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $null }
    if (-not $script:activityByLog.ContainsKey($LogPath)) {
        $script:activityByLog[$LogPath] = @{ Length = -1L; State = $null; Token = -1L; CompletedTurnId = $null }
    }
    $entry = $script:activityByLog[$LogPath]
    try {
        $probe = [CodexGroupy.ActivityLogProbeV1]::Probe($LogPath, [long]$entry.Length, [string]$entry.State, [long]$entry.Token)
    }
    catch {
        # A rollout can be rotated or momentarily locked while Codex writes it. Keep the last
        # known state for this 350 ms pass instead of blocking the Groupy UI path.
        return [pscustomobject]@{ State = $entry.State; CompletedTurnId = $entry.CompletedTurnId }
    }
    $entry.Length = $probe.Length
    $entry.State = $probe.State
    $entry.Token = $probe.Token
    $entry.CompletedTurnId = if ($probe.State -eq 'finished') { "offset:$($probe.Token)" } else { $null }
    return [pscustomobject]@{ State = $entry.State; CompletedTurnId = $entry.CompletedTurnId }
}

function Get-LiveActivityState([string]$ThreadId) {
    if (-not $ThreadId -or -not $script:liveActivityByThread.ContainsKey($ThreadId)) { return $null }
    $entry = $script:liveActivityByThread[$ThreadId]
    if ($entry.State -eq 'working' -and ((Get-Date) - $entry.UpdatedAt).TotalMinutes -gt 45) {
        $entry.State = 'stopped'
        $entry.CompletedTurnId = $null
    }
    return [pscustomobject]@{ State = $entry.State; CompletedTurnId = $entry.CompletedTurnId }
}

function Test-LiveLifecycleBridgeReady {
    if ($DisableLiveLifecycleBridge) { return $false }
    foreach ($bridge in @($script:activityBridges.Values)) {
        if ($bridge.Ready) { return $true }
    }
    return $false
}

function Get-DisplayActivityState([IntPtr]$Handle, [object]$Chat) {
    $activity = Get-LiveActivityState $Chat.ThreadId
    if ($AllGroupsCached -and (Test-LiveLifecycleBridgeReady) -and (-not $activity -or -not $activity.State)) {
        $key = $Handle.ToInt64().ToString('X')
        $script:latestLifecycleByWindow[$key] = '<none>'
        return $null
    }
    if (-not $activity -or -not $activity.State) {
        $activity = Get-ActivityState $Chat.LogPath
        if ((Test-LiveLifecycleBridgeReady) -and $activity -and $activity.State -eq 'working') {
            # Rollout JSONL writes can lag behind the actual VS Code turn state; once the live
            # bridge is ready, never let an old unclosed task_started resurrect a yellow dot.
            $activity = $null
        }
    }
    $key = $Handle.ToInt64().ToString('X')
    $script:latestLifecycleByWindow[$key] = if ($activity -and $activity.State) { $activity.State } else { '<none>' }
    if (-not $activity -or -not $activity.State) { return $null }
    if (-not $script:displayActivityByWindow.ContainsKey($key)) {
        # A helper restart cannot know whether an old completion was already read. Establish a
        # baseline on first sight; only a completion observed after this process saw the turn
        # working earns the unread-green badge.
        $script:displayActivityByWindow[$key] = @{ LastThreadId = $null; CompletedTurnId = $null; Unread = $false; Initialized = $false; WasWorking = $false }
    }
    $entry = $script:displayActivityByWindow[$key]
    $isFocused = ([CodexGroupy.ActivityDotsNativeV1]::GetForegroundWindow() -eq $Handle)
    if ($activity.State -eq 'working') {
        $entry.LastThreadId = $Chat.ThreadId
        $entry.CompletedTurnId = $null
        $entry.Unread = $false
        $entry.Initialized = $true
        $entry.WasWorking = $true
        return 'working'
    }
    if ($activity.State -eq 'stopped') {
        $entry.LastThreadId = $Chat.ThreadId
        $entry.CompletedTurnId = $null
        $entry.Unread = $false
        $entry.Initialized = $true
        $entry.WasWorking = $false
        return $null
    }
    if ($activity.State -ne 'finished') { return $null }

    # The first finished state is a baseline, not evidence of a new unread completion. Thereafter
    # green requires a working -> finished transition observed by this helper while this exact
    # VS Code window was not focused. Focusing acknowledges it before drawing.
    if (-not $entry.Initialized -or $entry.LastThreadId -ne $Chat.ThreadId) {
        $entry.LastThreadId = $Chat.ThreadId
        $entry.CompletedTurnId = $activity.CompletedTurnId
        $entry.Unread = $false
        $entry.Initialized = $true
        $entry.WasWorking = $false
    }
    elseif ($entry.CompletedTurnId -ne $activity.CompletedTurnId) {
        $entry.CompletedTurnId = $activity.CompletedTurnId
        $entry.Unread = $entry.WasWorking -and -not $isFocused
        $entry.WasWorking = $false
    }
    if ($isFocused) { $entry.Unread = $false }
    if ($entry.Unread) { return 'finished' }
    return $null
}

function Resolve-CodexChatForWindow([IntPtr]$Handle) {
    $key = $Handle.ToInt64().ToString('X')
    $caption = [CodexGroupy.ActivityDotsNativeV1]::ReadWindowTitle($Handle)
    $title = ConvertTo-CodexTitleKey $caption
    if ($title -and $script:logByTitle.ContainsKey($title)) {
        $chat = $script:logByTitle[$title]
        if (-not $chat.LogPath) { $chat.LogPath = Resolve-CodexSessionLogPath $chat.ThreadId }
        if ($chat.LogPath) {
            $script:chatByWindow[$key] = $chat
            return $chat
        }
        return $null
    }
    # The title watcher intentionally labels these explicit non-chat states. Clear a prior cached
    # chat only for those known state changes; editor captions during a tab switch are transient.
    if ($title -match '(?i)\s-\sCodex\s+(home|closed)$') {
        $script:chatByWindow.Remove($key)
        return $null
    }
    # An unresolved caption must never inherit the prior chat's indicator. A brief missing dot
    # during VS Code's own caption refresh is preferable to displaying activity for the wrong tab.
    $script:chatByWindow.Remove($key)
    return $null
}

function Get-CodexExtensionHostInspectorUrls {
    # VS Code 1.131 exposes extension hosts as NodeService utility processes. Their local
    # Inspector endpoint is also what the rename helper uses to reach the live app-server client.
    $cachedUrls = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $script:inspectorCachePath) {
        try {
            foreach ($cachedUrl in @([System.IO.File]::ReadAllLines($script:inspectorCachePath))) {
                $cachedUrl = $cachedUrl.Trim()
                if (-not $cachedUrl -or $cachedUrl -notmatch '^ws://([^/]+)/') { continue }
                try {
                    $endpoint = Invoke-RestMethod -Uri ("http://{0}/json/list" -f $Matches[1]) -TimeoutSec 1 -ErrorAction Stop
                    foreach ($entry in @($endpoint)) {
                        if ($entry.type -eq 'node' -and [string]$entry.webSocketDebuggerUrl -eq $cachedUrl) {
                            [void]$cachedUrls.Add($cachedUrl)
                        }
                    }
                }
                catch {
                    # This cached extension host probably exited.
                }
            }
        }
        catch {
            # Ignore a corrupt cache; full discovery below will rewrite it.
        }
    }
    if ($cachedUrls.Count -gt 0 -and ((Get-Date) - $script:lastFullInspectorDiscoveryAt).TotalSeconds -lt 60) {
        return @($cachedUrls | Select-Object -Unique)
    }
    $script:lastFullInspectorDiscoveryAt = Get-Date

    $extensionHosts = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -match '--utility-sub-type=node\.mojom\.NodeService' -and
            $_.CommandLine -match '--inspect-port=0'
        }
    $hostPids = @{}
    foreach ($extensionHost in @($extensionHosts)) { $hostPids[[int]$extensionHost.ProcessId] = $true }
    $urls = [Collections.Generic.List[string]]::new()
    foreach ($cachedUrl in @($cachedUrls)) { [void]$urls.Add($cachedUrl) }
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $hostPids.ContainsKey([int]$_.OwningProcess) -and $_.LocalAddress -in @('127.0.0.1', '::1') }
    $bridgeDiscoverySignature = "hosts=$(@($extensionHosts).Count);listeners=$(@($listeners).Count)"
    if ($bridgeDiscoverySignature -ne $script:lastBridgeDiscoverySignature) {
        $script:lastBridgeDiscoverySignature = $bridgeDiscoverySignature
        Write-ActivityDiagnostic "bridge-discovery $bridgeDiscoverySignature"
    }
    foreach ($listener in @($listeners)) {
        $hostPart = if ($listener.LocalAddress -eq '::1') { '[::1]' } else { '127.0.0.1' }
        try {
            $endpoint = Invoke-RestMethod -Uri ("http://{0}:{1}/json/list" -f $hostPart, $listener.LocalPort) -TimeoutSec 1 -ErrorAction Stop
            foreach ($entry in @($endpoint)) {
                if ($entry.type -eq 'node' -and $entry.webSocketDebuggerUrl) { [void]$urls.Add([string]$entry.webSocketDebuggerUrl) }
            }
        }
        catch {
            # A non-Codex local Node service can use another VS Code listener; ignore it.
        }
    }
    $result = @($urls | Select-Object -Unique)
    if ($result.Count -gt 0) {
        try { [System.IO.File]::WriteAllLines($script:inspectorCachePath, [string[]]$result) } catch {}
    }
    elseif ($cachedUrls.Count -eq 0 -and (Test-Path -LiteralPath $script:inspectorCachePath)) {
        try { Remove-Item -LiteralPath $script:inspectorCachePath -Force -ErrorAction SilentlyContinue } catch {}
    }
    return $result
}

function Remove-BridgePendingRequests([string]$BridgeUrl) {
    $keys = @($script:pendingRequestsByKey.Keys | Where-Object { $_.StartsWith("$BridgeUrl|") })
    foreach ($key in $keys) { $script:pendingRequestsByKey.Remove($key) }
}

function Start-ActivityBridge([string]$BridgeUrl) {
    $node = Get-Command node -CommandType Application -ErrorAction Stop
    $bridge = Join-Path $PSScriptRoot 'CodexVsCodeLiveRenameBridge.js'
    if (-not (Test-Path -LiteralPath $bridge)) { throw "Missing live Codex bridge: $bridge" }
    $operation = if ($DisableLiveLifecycleBridge) { 'watch-activity' } else { 'trace-activity' }
    $process = [CodexGroupy.ActivityBridgeProcessV1]::new($node.Source, $bridge, $BridgeUrl, $operation)
    $script:activityBridges[$BridgeUrl] = [pscustomobject]@{ Process = $process; Ready = $false }
}

function Set-LiveThreadActivity([string]$ThreadId, [string]$State, [object]$TurnId) {
    if (-not $ThreadId -or -not $State) { return }
    $existing = if ($script:liveActivityByThread.ContainsKey($ThreadId)) { $script:liveActivityByThread[$ThreadId] } else { $null }
    $completedId = if ($State -eq 'finished') {
        if ($TurnId) { "live:$TurnId" }
        elseif ($existing -and $existing.State -eq 'finished' -and $existing.CompletedTurnId) { $existing.CompletedTurnId }
        else { "live:$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" }
    } else { $null }
    if ($existing -and $existing.State -eq $State -and [string]$existing.CompletedTurnId -eq [string]$completedId) {
        $existing.UpdatedAt = Get-Date
        return
    }
    $script:liveActivityByThread[$ThreadId] = [pscustomobject]@{
        State = $State
        CompletedTurnId = $completedId
        UpdatedAt = Get-Date
    }
    if ($AllGroupsCached -and $State -eq 'working' -and -not $script:stripKeysByThread.ContainsKey($ThreadId)) {
        $script:unmappedWorkingRetryUntil = (Get-Date).AddSeconds(10)
        $script:nextUnmappedWorkingRetryAt = [DateTime]::MinValue
    }
    Set-ActivityThreadDirty $ThreadId "live-thread:$ThreadId"
    Write-ActivityDiagnostic "live-thread thread=$ThreadId state=$State turn=$(if ($TurnId) { $TurnId } else { '<none>' })"
}

function Update-LiveThreadActivityFromNotification([object]$Message) {
    if (-not $Message.threadId -or -not $Message.method) { return }
    $method = [string]$Message.method
    $turnId = if ($Message.PSObject.Properties['turnId'] -and $Message.turnId) { $Message.turnId } else { $null }
    $status = ''
    if ($Message.PSObject.Properties['status'] -and $Message.status) {
        if ($Message.status -is [string]) { $status = [string]$Message.status }
        elseif ($Message.status.PSObject.Properties['type']) { $status = [string]$Message.status.type }
    }
    $itemType = if ($Message.PSObject.Properties['itemType'] -and $Message.itemType) { [string]$Message.itemType } else { '' }
    if ($method -match '^(turn|task|thread/status|item)/') {
        $signature = "$method|$status|$itemType"
        if (-not $script:liveNotificationSignatures.ContainsKey($signature)) {
            $script:liveNotificationSignatures[$signature] = $true
            Write-ActivityDiagnostic "live-notification method=$method status=$(if ($status) { $status } else { '<none>' }) itemType=$(if ($itemType) { $itemType } else { '<none>' })"
        }
    }
    switch -Regex ($method) {
        '^(turn|task)/started$' { Set-LiveThreadActivity ([string]$Message.threadId) 'working' $turnId; break }
        '^(turn|task)/(completed|complete)$' { Set-LiveThreadActivity ([string]$Message.threadId) 'finished' $turnId; break }
        '^(turn|task)/(aborted|cancelled|canceled|failed|error)$' { Set-LiveThreadActivity ([string]$Message.threadId) 'stopped' $turnId; break }
        '^thread/status/(updated|changed)$' {
            if ($status -eq 'active') { Set-LiveThreadActivity ([string]$Message.threadId) 'working' $turnId }
            elseif ($status -in @('idle', 'systemError', 'notLoaded')) { Set-LiveThreadActivity ([string]$Message.threadId) 'finished' $turnId }
            break
        }
    }
}

function Read-ActivityBridgeOutput {
    foreach ($bridgeUrl in @($script:activityBridges.Keys)) {
        $bridge = $script:activityBridges[$bridgeUrl]
        $process = $bridge.Process
        if ($process.HasExited) {
            Remove-BridgePendingRequests $bridgeUrl
            $process.Dispose()
            $script:activityBridges.Remove($bridgeUrl)
            continue
        }
        foreach ($line in $process.Drain()) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.StartsWith('# bridge-error:')) {
                Write-ActivityDiagnostic $line
                continue
            }
            try { $message = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($message.type -eq 'ready') {
                $bridge.Ready = $true
                Remove-BridgePendingRequests $bridgeUrl
                foreach ($pending in @($message.pending)) {
                    if (-not $pending.threadId -or -not $pending.requestId) { continue }
                    $script:pendingRequestsByKey["$bridgeUrl|$($pending.requestId)"] = [pscustomobject]@{ ThreadId = [string]$pending.threadId; Kind = [string]$pending.kind }
                }
            }
            elseif ($message.type -eq 'pending' -and $message.threadId -and $message.requestId) {
                $script:pendingRequestsByKey["$bridgeUrl|$($message.requestId)"] = [pscustomobject]@{ ThreadId = [string]$message.threadId; Kind = [string]$message.kind }
            }
            elseif ($message.type -eq 'resolved' -and $message.requestId) {
                $script:pendingRequestsByKey.Remove("$bridgeUrl|$($message.requestId)")
            }
            elseif ($message.type -eq 'notification') {
                Update-LiveThreadActivityFromNotification $message
            }
        }
    }
}

function Refresh-ActivityBridges {
    Read-ActivityBridgeOutput
    $liveBridgeCount = @($script:activityBridges.Values | Where-Object { -not $_.Process.HasExited }).Count
    $discoveryIntervalSeconds = if ($liveBridgeCount -gt 0) { 60 } else { 90 }
    if (((Get-Date) - $script:lastActivityBridgeDiscoveryAt).TotalSeconds -lt $discoveryIntervalSeconds) { return }
    $script:lastActivityBridgeDiscoveryAt = Get-Date
    foreach ($bridgeUrl in Get-CodexExtensionHostInspectorUrls) {
        if ($script:activityBridges.ContainsKey($bridgeUrl)) { continue }
        try { Start-ActivityBridge $bridgeUrl } catch {}
    }
}

function Test-CodexThreadNeedsUser([string]$ThreadId) {
    if (-not $ThreadId) { return $false }
    return @($script:pendingRequestsByKey.Values | Where-Object { $_.ThreadId -eq $ThreadId }).Count -gt 0
}

function Get-GroupyTabs([IntPtr]$Strip) {
    try {
        if (-not $script:groupyController) {
            $controller = Get-Process GroupyCtrl -ErrorAction Stop | Select-Object -First 1
            $module = $controller.Modules | Where-Object { $_.ModuleName -eq 'GroupyCtrl.exe' } | Select-Object -First 1
            if (-not $module) { return @() }
            $script:groupyController = [pscustomobject]@{ Id = [uint32]$controller.Id; BaseAddress = $module.BaseAddress.ToInt64() }
        }
        return @([CodexGroupy.ActivityDotsNativeV1]::ReadTabs($script:groupyController.Id, $script:groupyController.BaseAddress, $Strip))
    }
    catch {
        # Groupy can restart independently. Rediscover its PID/module on the next pass.
        $script:groupyController = $null
        return @()
    }
}

if ($Inspect) {
    Update-CodexSessionMap
    $foreground = [CodexGroupy.ActivityDotsNativeV1]::GetForegroundWindow()
    if (-not $AllGroups -and -not [CodexGroupy.ActivityDotsNativeV1]::IsCodeWindow($foreground)) {
        Write-Output 'Foreground window is not VS Code.'
        return
    }
    $activeStrip = if ([CodexGroupy.ActivityDotsNativeV1]::IsCodeWindow($foreground)) { [CodexGroupy.ActivityDotsNativeV1]::GetProp($foreground, 'GP_LINK') } else { [IntPtr]::Zero }
    if (-not $AllGroups -and $activeStrip -eq [IntPtr]::Zero) {
        Write-Output 'Foreground VS Code window is not linked to a Groupy strip.'
        return
    }
    $inspectStrips = if ($AllGroups) { @([CodexGroupy.ActivityDotsNativeV1]::GetCodeGroupStrips()) } else { @($activeStrip) }
    $rows = foreach ($strip in $inspectStrips) {
        foreach ($tab in Get-GroupyTabs $strip) {
            $handle = [IntPtr]$tab.Handle
            $caption = [CodexGroupy.ActivityDotsNativeV1]::ReadWindowTitle($handle)
            $chat = Resolve-CodexChatForWindow $handle
            $activity = if ($chat) { Get-ActivityState $chat.LogPath } else { $null }
            $display = if ($chat) { Get-DisplayActivityState $handle $chat } else { $null }
            $rolloutItem = if ($chat -and $chat.LogPath -and (Test-Path -LiteralPath $chat.LogPath)) { Get-Item -LiteralPath $chat.LogPath } else { $null }
            [pscustomobject]@{
                Strip = ('0x{0:X}' -f $strip.ToInt64())
                Handle = ('0x{0:X}' -f $handle.ToInt64())
                Caption = $caption
                ThreadId = if ($chat) { $chat.ThreadId } else { '<unresolved>' }
                Lifecycle = if ($activity) { $activity.State } else { '<none>' }
                Display = if ($display) { $display } else { '<none>' }
                Rollout = if ($chat) { Split-Path -Leaf $chat.LogPath } else { '<none>' }
                RolloutBytes = if ($rolloutItem) { $rolloutItem.Length } else { 0 }
                RolloutWriteUtc = if ($rolloutItem) { $rolloutItem.LastWriteTimeUtc.ToString('O') } else { '<none>' }
            }
        }
    }
    $rows | Format-Table -AutoSize -Wrap
    return
}

function New-ActivityOverlay([IntPtr]$Owner, [switch]$UseTopmost) {
    $window = [System.Windows.Window]::new()
    $window.Width = 1
    $window.Height = 1
    $window.WindowStyle = 'None'
    $window.ResizeMode = 'NoResize'
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    # The default single-strip overlay is topmost only while VS Code owns the foreground. The
    # multi-group experiment instead uses per-strip ownership so background groups can be visible.
    $window.Topmost = [bool]$UseTopmost
    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $window.Focusable = $false

    $canvas = [System.Windows.Controls.Canvas]::new()
    $canvas.IsHitTestVisible = $false
    $window.Content = $canvas
    $ownerForInit = $Owner
    $window.Add_SourceInitialized({
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        # Click-through + no-activate + tool window: visual-only, never an Alt+Tab entry.
        $style = [CodexGroupy.ActivityDotsNativeV1]::GetWindowLongPtr($handle, -20).ToInt64()
        $style = $style -bor 0x20 -bor 0x80 -bor 0x08000000
        [void][CodexGroupy.ActivityDotsNativeV1]::SetWindowLongPtr($handle, -20, [IntPtr]$style)
        if ($ownerForInit -ne [IntPtr]::Zero) {
            # An owned window stays directly above its Groupy strip, but is naturally covered by
            # other foreground apps (unlike a global topmost overlay).
            [void][CodexGroupy.ActivityDotsNativeV1]::SetWindowLongPtr($handle, -8, $ownerForInit)
        }
        # WPF's IsHitTestVisible only affects controls inside this window. Return HTTRANSPARENT at
        # the native window boundary too, so manual Groupy tab clicks pass straight through.
        $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
        $mousePassthrough = [System.Windows.Interop.HwndSourceHook]{
            param([IntPtr]$hwnd, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
            if ($message -eq 0x0084) {
                $handled.Value = $true
                return [IntPtr](-1) # HTTRANSPARENT
            }
            return [IntPtr]::Zero
        }
        $source.AddHook($mousePassthrough)
    }.GetNewClosure())
    $window.Show(); $window.Hide()
    return [pscustomobject]@{ Window = $window; Canvas = $canvas; Owner = $Owner; LastSignature = $null; LastDiagnosticsSignature = $null; VisualsByKey = @{} }
}

function Hide-ActivityOverlay([object]$Overlay) {
    if ($Overlay.Window.IsVisible) { $Overlay.Window.Hide() }
}

function Hide-AllActivityOverlays {
    foreach ($overlay in @($script:overlaysByStrip.Values)) {
        try { Hide-ActivityOverlay $overlay } catch {}
    }
}

function Set-ActivityStripDirty([IntPtr]$Strip, [string]$Reason) {
    if ($Strip -eq [IntPtr]::Zero) { return }
    $script:dirtyActivityStrips[$Strip.ToInt64().ToString('X')] = $Reason
}

function Set-AllActivityStripsDirty([string]$Reason) {
    foreach ($strip in @($script:cachedGroupStrips)) { Set-ActivityStripDirty $strip $Reason }
    foreach ($key in @($script:overlaysByStrip.Keys)) { $script:dirtyActivityStrips[$key] = $Reason }
}

function Set-ActivityThreadDirty([string]$ThreadId, [string]$Reason) {
    if (-not $ThreadId) { return }
    if ($script:stripKeysByThread.ContainsKey($ThreadId) -and $script:stripKeysByThread[$ThreadId].Count -gt 0) {
        foreach ($key in @($script:stripKeysByThread[$ThreadId].Keys)) {
            $script:dirtyActivityStrips[$key] = $Reason
        }
        return
    }
    Set-AllActivityStripsDirty $Reason
}

function Get-LiveActivityStrips {
    if (-not $AllGroupsCached) {
        if ($AllGroups) { return @([CodexGroupy.ActivityDotsNativeV1]::GetCodeGroupStrips()) }
        $foreground = [CodexGroupy.ActivityDotsNativeV1]::GetForegroundWindow()
        $strip = if ([CodexGroupy.ActivityDotsNativeV1]::IsCodeWindow($foreground)) { [CodexGroupy.ActivityDotsNativeV1]::GetProp($foreground, 'GP_LINK') } else { [IntPtr]::Zero }
        if ($strip -ne [IntPtr]::Zero) { return @($strip) }
        return @()
    }

    $now = Get-Date
    if ($script:cachedGroupStrips.Count -gt 0 -and (($now - $script:lastGroupStripDiscoveryAt).TotalSeconds -lt 30)) {
        return @($script:cachedGroupStrips)
    }
    $script:lastGroupStripDiscoveryAt = $now
    $nextStrips = @([CodexGroupy.ActivityDotsNativeV1]::GetCodeGroupStrips())
    $nextSignature = (@($nextStrips | ForEach-Object { $_.ToInt64().ToString('X') } | Sort-Object) -join ',')
    if ($nextSignature -ne $script:cachedGroupStripsSignature) {
        $script:cachedGroupStripsSignature = $nextSignature
        $script:cachedGroupStrips = @($nextStrips)
        foreach ($strip in @($script:cachedGroupStrips)) { Set-ActivityStripDirty $strip 'strip-discovery' }
    }
    return @($script:cachedGroupStrips)
}

function Write-AllGroupsStats([object[]]$LiveStrips) {
    if (-not $AllGroupsCached) { return }
    $overlayCount = $script:overlaysByStrip.Count
    $stripCount = @($LiveStrips).Count
    $signature = "$stripCount|$overlayCount"
    if ($signature -eq $script:allGroupsLastStatsSignature) { return }
    $script:allGroupsLastStatsSignature = $signature
    Write-ActivityDiagnostic "allgroups-cache strips=$stripCount overlays=$overlayCount"
}

function Get-VisibleTabOwner([object[]]$Tabs) {
    # In the normal active-strip mode the foreground VS Code HWND is the sole authoritative
    # active tab. Groupy can leave more than one member visible during transitions, so tab-order
    # scanning is not safe for move/resize or diagnostics.
    $foreground = [CodexGroupy.ActivityDotsNativeV1]::GetForegroundWindow()
    foreach ($tab in $Tabs) {
        $handle = [IntPtr]$tab.Handle
        if ($handle -eq $foreground -and [CodexGroupy.ActivityDotsNativeV1]::IsWindowVisible($handle) -and -not [CodexGroupy.ActivityDotsNativeV1]::IsIconic($handle)) { return $handle }
    }
    return [IntPtr]::Zero
}

function Get-AnyVisibleTabOwner([object[]]$Tabs) {
    foreach ($tab in $Tabs) {
        $handle = [IntPtr]$tab.Handle
        if ([CodexGroupy.ActivityDotsNativeV1]::IsWindowVisible($handle) -and -not [CodexGroupy.ActivityDotsNativeV1]::IsIconic($handle)) { return $handle }
    }
    return [IntPtr]::Zero
}

function Update-ActivityOverlay([IntPtr]$Strip, [object]$Overlay) {
    $tabs = @(Get-GroupyTabs $Strip)
    $visibleTab = if ($AllGroups -or $AllGroupsCached) { Get-AnyVisibleTabOwner $tabs } else { Get-VisibleTabOwner $tabs }
    if ($visibleTab -eq [IntPtr]::Zero -or [CodexGroupy.ActivityDotsNativeV1]::IsMoveSizeActive($visibleTab)) { Hide-ActivityOverlay $Overlay; return }

    $stripRect = [CodexGroupy.ActivityDotsNativeV1+RECT]::new()
    if (-not [CodexGroupy.ActivityDotsNativeV1]::GetWindowRect($Strip, [ref]$stripRect)) { Hide-ActivityOverlay $Overlay; return }

    $source = [System.Windows.PresentationSource]::FromVisual($Overlay.Window)
    $fromDevice = if ($source) { $source.CompositionTarget.TransformFromDevice } else { [System.Windows.Media.Matrix]::Identity }
    $topLeft = $fromDevice.Transform([System.Windows.Point]::new($stripRect.Left, $stripRect.Top))
    $bottomRight = $fromDevice.Transform([System.Windows.Point]::new($stripRect.Right, $stripRect.Bottom))
    $Overlay.Window.Left = $topLeft.X
    $Overlay.Window.Top = $topLeft.Y
    $Overlay.Window.Width = [Math]::Max(1, $bottomRight.X - $topLeft.X)
    $Overlay.Window.Height = [Math]::Max(1, $bottomRight.Y - $topLeft.Y)
    $dots = [Collections.Generic.List[object]]::new()
    $tabStates = [Collections.Generic.List[string]]::new()
    $threadsOnStrip = @{}
    $summaryCounts = @{ idle = 0; working = 0; finished = 0 }
    foreach ($tab in $tabs) {
        try {
            $tabHandle = [IntPtr]$tab.Handle
            $chat = Resolve-CodexChatForWindow $tabHandle
            if (-not $chat) {
                $tabStates.Add(('0x{0:X}|unresolved|<none>|<none>' -f $tabHandle.ToInt64()))
                continue
            }
            $threadsOnStrip[$chat.ThreadId] = $true
            # A genuine live request for input/approval overrides the normal lifecycle color.
            # It returns to yellow or green as soon as VS Code receives serverRequest/resolved.
            $state = if ($EnableNeedsUserBridge -and (Test-CodexThreadNeedsUser $chat.ThreadId)) { 'needs-user' } else { Get-DisplayActivityState $tabHandle $chat }
            $rawState = $script:latestLifecycleByWindow[$tabHandle.ToInt64().ToString('X')]
            $tabStates.Add(('0x{0:X}|{1}|{2}|{3}' -f $tabHandle.ToInt64(), $chat.ThreadId, $rawState, $(if ($state) { $state } else { '<none>' })))
            if ($state -eq 'working') { $summaryCounts.working++ }
            elseif ($state -eq 'finished') { $summaryCounts.finished++ }
            elseif (-not $state) { $summaryCounts.idle++ }
            if (-not $state) { continue }
            $dots.Add([pscustomobject]@{ Handle = $tabHandle; State = $state; Rect = $tab.Rect; ThreadId = $chat.ThreadId })
        }
        catch {
            # One transient title/log failure must not stop the active strip from refreshing or
            # leave that tab's previous indicator looking current.
            Write-ActivityDiagnostic "TAB ERROR strip=0x$($Strip.ToInt64().ToString('X')); tab=0x$(([IntPtr]$tab.Handle).ToInt64().ToString('X')); $($_.Exception.Message)"
        }
    }
    if ($AllGroupsCached) {
        $stripKey = $Strip.ToInt64().ToString('X')
        $script:activitySummaryByStrip[$stripKey] = $summaryCounts
        foreach ($threadId in @($script:stripKeysByThread.Keys)) {
            if ($threadsOnStrip.ContainsKey($threadId)) { continue }
            if (-not $script:stripKeysByThread[$threadId].ContainsKey($stripKey)) { continue }
            $script:stripKeysByThread[$threadId].Remove($stripKey)
            if ($script:stripKeysByThread[$threadId].Count -eq 0) { $script:stripKeysByThread.Remove($threadId) }
        }
        foreach ($threadId in @($threadsOnStrip.Keys)) {
            if (-not $script:stripKeysByThread.ContainsKey($threadId)) { $script:stripKeysByThread[$threadId] = @{} }
            $script:stripKeysByThread[$threadId][$stripKey] = $true
        }
    }

    $signature = ($dots | ForEach-Object { "$($_.Handle.ToInt64())|$($_.State)|$($_.Rect.Left),$($_.Rect.Top),$($_.Rect.Right),$($_.Rect.Bottom)" }) -join ';'
    $diagnosticSignature = "$($Strip.ToInt64())|$($visibleTab.ToInt64())|$signature|$($tabStates -join ';')"
    if ($diagnosticSignature -ne $Overlay.LastDiagnosticsSignature) {
        $Overlay.LastDiagnosticsSignature = $diagnosticSignature
        Write-ActivityDiagnostic "strip=0x$($Strip.ToInt64().ToString('X')); visibleTab=0x$($visibleTab.ToInt64().ToString('X')); dots=$signature; tabs=$($tabStates -join ';')"
    }
    # Do not leave a full-strip transparent topmost window alive when there is nothing to draw.
    # Apart from avoiding needless composition work, this keeps normal Groupy hit-testing wholly
    # native for the common no-activity case.
    if ($dots.Count -eq 0) {
        $Overlay.LastSignature = $signature
        foreach ($visualKey in @($Overlay.VisualsByKey.Keys)) {
            [void]$Overlay.Canvas.Children.Remove($Overlay.VisualsByKey[$visualKey].Ellipse)
            $Overlay.VisualsByKey.Remove($visualKey)
        }
        Hide-ActivityOverlay $Overlay
        return
    }
    if (-not $Overlay.Window.IsVisible) { $Overlay.Window.Show() }
    if ($signature -eq $Overlay.LastSignature) { return }
    $Overlay.LastSignature = $signature
    $liveVisualKeys = @{}
    foreach ($dot in $dots) {
        $visualKey = $dot.Handle.ToInt64().ToString('X')
        $liveVisualKeys[$visualKey] = $true
        # Groupy's stored tab rectangles are already client coordinates relative to its strip,
        # which is exactly this overlay canvas. Do not subtract the strip's screen position.
        $rightPoint = $fromDevice.Transform([System.Windows.Point]::new($dot.Rect.Right - $DotRightPaddingPixels - $DotDiameterPixels, $dot.Rect.Top + (($dot.Rect.Bottom - $dot.Rect.Top - $DotDiameterPixels) / 2)))
        $visual = if ($Overlay.VisualsByKey.ContainsKey($visualKey)) { $Overlay.VisualsByKey[$visualKey] } else { $null }
        if (-not $visual -or $visual.State -ne $dot.State) {
            if ($visual) { [void]$Overlay.Canvas.Children.Remove($visual.Ellipse) }
            $ellipse = [System.Windows.Shapes.Ellipse]::new()
            $ellipse.Width = $fromDevice.Transform([System.Windows.Point]::new($DotDiameterPixels, 0)).X
            $ellipse.Height = $fromDevice.Transform([System.Windows.Point]::new(0, $DotDiameterPixels)).Y
            $ellipse.Fill = switch ($dot.State) {
                'working' { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(255, 205, 20)); break }
                'needs-user' { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(255, 145, 35)); break }
                default { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(67, 201, 109)) }
            }
            [void]$Overlay.Canvas.Children.Add($ellipse)
            $visual = [pscustomobject]@{ Ellipse = $ellipse; State = $dot.State }
            $Overlay.VisualsByKey[$visualKey] = $visual
            if ($dot.State -eq 'working') {
                # Do not use WPF's continuous animation clock here. Multiple cross-window opacity
                # animations were measurable as CPU and showed up as VS Code scroll/type hitches.
                # A tiny manual heartbeat below gives the "alive" signal without repainting at
                # monitor refresh rate.
                $ellipse.Opacity = [double]$script:workingPulseOpacities[$script:workingPulseIndex]
            }
        }
        [System.Windows.Controls.Canvas]::SetLeft($visual.Ellipse, $rightPoint.X)
        [System.Windows.Controls.Canvas]::SetTop($visual.Ellipse, $rightPoint.Y)
    }
    foreach ($visualKey in @($Overlay.VisualsByKey.Keys)) {
        if ($liveVisualKeys.ContainsKey($visualKey)) { continue }
        [void]$Overlay.Canvas.Children.Remove($Overlay.VisualsByKey[$visualKey].Ellipse)
        $Overlay.VisualsByKey.Remove($visualKey)
    }
}

function Update-WorkingDotPulse {
    $hasWorkingDot = $false
    $opacity = [double]$script:workingPulseOpacities[$script:workingPulseIndex]
    foreach ($overlay in @($script:overlaysByStrip.Values)) {
        foreach ($visual in @($overlay.VisualsByKey.Values)) {
            if ($visual.State -ne 'working') { continue }
            $hasWorkingDot = $true
            try { $visual.Ellipse.Opacity = $opacity } catch {}
        }
    }
    if ($hasWorkingDot) { $script:workingPulseIndex = ($script:workingPulseIndex + 1) % $script:workingPulseOpacities.Count }
}

function Update-ActivityDots {
    $stageWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stageTimings = [Collections.Generic.List[string]]::new()
    $lastStageMs = 0L
    function Add-StageTiming([string]$Name) {
        $nowMs = $stageWatch.ElapsedMilliseconds
        $delta = $nowMs - $script:lastStageMsForUpdate
        $script:lastStageMsForUpdate = $nowMs
        if ($delta -ge 100) { $stageTimings.Add("$Name=$delta") }
    }
    $script:lastStageMsForUpdate = 0L
    $moveActive = [CodexGroupy.ActivityDotsNativeV1]::IsAnyMoveSizeActive()
    if ($moveActive) {
        if (-not $script:lastMoveActive) {
            $script:lastMoveActive = $true
            Write-ActivityDiagnostic 'move-start; overlays hidden'
        }
        Hide-AllActivityOverlays
        return
    }
    if ($script:lastMoveActive) {
        $script:lastMoveActive = $false
        Set-AllActivityStripsDirty 'move-end'
        Write-ActivityDiagnostic 'move-end; overlays dirty'
    }
    Add-StageTiming 'move-check'
    Update-CodexSessionMap
    Add-StageTiming 'session-map'
    if ($EnableNeedsUserBridge -or -not $DisableLiveLifecycleBridge) { Refresh-ActivityBridges }
    Add-StageTiming 'bridges'
    $liveStrips = @(Get-LiveActivityStrips)
    Add-StageTiming 'strips'
    Write-AllGroupsStats $liveStrips
    Update-SessionFileDirtyState
    Add-StageTiming 'session-watch'
    $foreground = [CodexGroupy.ActivityDotsNativeV1]::GetForegroundWindow()
    $foregroundRaw = $foreground.ToInt64()
    if ($foregroundRaw -ne $script:lastForegroundHandleRaw) {
        $script:lastForegroundHandleRaw = $foregroundRaw
        if ($AllGroupsCached) {
            if ([CodexGroupy.ActivityDotsNativeV1]::IsCodeWindow($foreground)) {
                $foregroundStrip = [CodexGroupy.ActivityDotsNativeV1]::GetProp($foreground, 'GP_LINK')
                if ($foregroundStrip -ne [IntPtr]::Zero) {
                    $foregroundStripKey = $foregroundStrip.ToInt64().ToString('X')
                    $knownStripKeys = @($script:cachedGroupStrips | ForEach-Object { $_.ToInt64().ToString('X') })
                    if ($knownStripKeys -notcontains $foregroundStripKey) {
                        $script:cachedGroupStrips = @($script:cachedGroupStrips) + @($foregroundStrip)
                        $script:cachedGroupStripsSignature = (@($script:cachedGroupStrips | ForEach-Object { $_.ToInt64().ToString('X') } | Sort-Object) -join ',')
                        Set-ActivityStripDirty $foregroundStrip 'foreground-new-strip'
                    }
                }
            }
            Set-AllActivityStripsDirty 'foreground'
        }
    }
    if ($AllGroupsCached) {
        $now = Get-Date
        if ($now -lt $script:unmappedWorkingRetryUntil -and $now -ge $script:nextUnmappedWorkingRetryAt) {
            $unmappedWorking = $false
            foreach ($threadId in @($script:liveActivityByThread.Keys)) {
                $entry = $script:liveActivityByThread[$threadId]
                if ($entry.State -eq 'working' -and -not $script:stripKeysByThread.ContainsKey($threadId)) {
                    $unmappedWorking = $true
                    break
                }
            }
            if ($unmappedWorking) {
                Set-AllActivityStripsDirty 'unmapped-working-retry'
                $script:nextUnmappedWorkingRetryAt = $now.AddSeconds(1.5)
            }
            else {
                $script:unmappedWorkingRetryUntil = [DateTime]::MinValue
            }
        }
    }
    $liveKeys = @{}
    foreach ($strip in $liveStrips) {
        $key = $strip.ToInt64().ToString('X')
        $liveKeys[$key] = $true
        if (-not $script:overlaysByStrip.ContainsKey($key)) {
            $owner = if ($AllGroups -or $AllGroupsCached) { $strip } else { [IntPtr]::Zero }
            $script:overlaysByStrip[$key] = New-ActivityOverlay -Owner $owner -UseTopmost:(-not ($AllGroups -or $AllGroupsCached))
            if ($AllGroupsCached) { $script:dirtyActivityStrips[$key] = 'new-overlay' }
        }
        if ($AllGroupsCached -and -not $script:dirtyActivityStrips.ContainsKey($key)) {
            continue
        }
        try {
            $renderWatch = [System.Diagnostics.Stopwatch]::StartNew()
            Update-ActivityOverlay $strip $script:overlaysByStrip[$key]
            $renderWatch.Stop()
            if ($AllGroupsCached) {
                $reason = $script:dirtyActivityStrips[$key]
                $script:dirtyActivityStrips.Remove($key)
                if ($renderWatch.ElapsedMilliseconds -ge 100) {
                    Write-ActivityDiagnostic "allgroups-render strip=0x$key reason=$reason elapsedMs=$($renderWatch.ElapsedMilliseconds)"
                }
            }
        }
        catch {
            # A bad Groupy record, DPI transition, or WPF failure must hide this strip rather
            # than preserving a stale dot until the next successful global tick.
            Write-ActivityDiagnostic "STRIP ERROR strip=0x$($strip.ToInt64().ToString('X')); $($_.Exception.Message)"
            Hide-ActivityOverlay $script:overlaysByStrip[$key]
        }
    }
    foreach ($key in @($script:overlaysByStrip.Keys)) {
        if ($liveKeys.ContainsKey($key)) { continue }
        $overlay = $script:overlaysByStrip[$key]
        Hide-ActivityOverlay $overlay
        $overlay.Window.Close()
        $script:overlaysByStrip.Remove($key)
        if ($script:activitySummaryByStrip.ContainsKey($key)) { $script:activitySummaryByStrip.Remove($key) }
    }
    if ($AllGroupsCached) { Publish-ActivitySummary }
    # A low-frequency watchdog proves the dispatcher is alive even when neither focus nor a
    # lifecycle state changes. It is deliberately best-effort and never participates in render.
    if (((Get-Date) - $script:lastHeartbeatAt).TotalSeconds -ge 15) {
        $script:lastHeartbeatAt = Get-Date
        $foreground = [CodexGroupy.ActivityDotsNativeV1]::GetForegroundWindow()
        $stripSummary = @($liveStrips | ForEach-Object { '0x{0:X}' -f $_.ToInt64() }) -join ','
            Write-ActivityDiagnostic "heartbeat; foreground=0x$($foreground.ToInt64().ToString('X')); strips=$stripSummary"
    }
    Add-StageTiming 'render'
    if ($AllGroupsCached -and $stageWatch.ElapsedMilliseconds -ge 750 -and $stageTimings.Count -gt 0) {
        Write-ActivityDiagnostic "SLOW STAGES elapsedMs=$($stageWatch.ElapsedMilliseconds) $($stageTimings -join ';')"
    }
}

$moveSizeHook = [CodexGroupy.ActivityDotsNativeV1]::StartMoveSizeHook()
if ($moveSizeHook -eq [IntPtr]::Zero) {
    Write-Warning 'Could not install the move/resize hook; activity dots will still work but may follow a window drag.'
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = if ($AllGroupsCached) { [TimeSpan]::FromMilliseconds(1000) } else { [TimeSpan]::FromMilliseconds(350) }
$timer.Add_Tick({
    $tickWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try { Update-ActivityDots }
    catch {
        # Never leave last tick's indicators onscreen after a global update failure.
        Hide-AllActivityOverlays
        Write-ActivityDiagnostic "UPDATE ERROR (all overlays hidden): $($_.Exception.Message)"
    }
    finally {
        $tickWatch.Stop()
        if ($tickWatch.ElapsedMilliseconds -ge 750) {
            Write-ActivityDiagnostic "SLOW UPDATE elapsedMs=$($tickWatch.ElapsedMilliseconds)"
        }
    }
})

$pulseTimer = [System.Windows.Threading.DispatcherTimer]::new()
$pulseTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$pulseTimer.Add_Tick({
    try { Update-WorkingDotPulse } catch {}
})

try { Update-ActivityDots }
catch {
    Hide-AllActivityOverlays
    Write-ActivityDiagnostic "INITIAL UPDATE ERROR (all overlays hidden): $($_.Exception.Message)"
}
$timer.Start()
$pulseTimer.Start()
if ($AllGroupsCached) {
    Write-Host 'Showing cached activity dots on every visible Groupy / VS Code tab strip. Press Ctrl+C to stop.'
}
elseif ($AllGroups) {
    Write-Host 'Showing activity dots on every visible Groupy / VS Code tab strip (legacy experimental multi-group mode). Press Ctrl+C to stop.'
}
else {
    Write-Host 'Showing activity dots on the active Groupy / VS Code tab strip. Press Ctrl+C to stop.'
}
Write-ActivityDiagnostic "Activity helper started; testSeconds=$TestSeconds."

$frame = [System.Windows.Threading.DispatcherFrame]::new()
$testTimer = $null
if ($TestSeconds -gt 0) {
    $testTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $testTimer.Interval = [TimeSpan]::FromSeconds($TestSeconds)
    $testTimer.Add_Tick({
        Write-ActivityDiagnostic "Test timer elapsed after $TestSeconds seconds; stopping activity helper."
        $testTimer.Stop()
        $frame.Continue = $false
    })
    $testTimer.Start()
}

try {
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
catch {
    Write-ActivityDiagnostic "DISPATCHER EXIT ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Write-ActivityDiagnostic "Activity helper stopping; frameContinue=$($frame.Continue); testSeconds=$TestSeconds."
    $timer.Stop()
    $pulseTimer.Stop()
    if ($testTimer) { $testTimer.Stop() }
    if ($moveSizeHook -ne [IntPtr]::Zero) { [void][CodexGroupy.ActivityDotsNativeV1]::UnhookWinEvent($moveSizeHook) }
    foreach ($bridge in @($script:activityBridges.Values)) {
        try { if (-not $bridge.Process.HasExited) { $bridge.Process.Stop() } } catch {}
        try { $bridge.Process.Dispose() } catch {}
    }
    if ($script:sessionFileWatcher) {
        foreach ($subscription in @($script:sessionFileWatcherSubscriptions)) {
            try { Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue } catch {}
        }
        foreach ($event in @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$($script:sessionFileWatcherSourcePrefix):*" })) {
            try { Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue } catch {}
        }
        try { $script:sessionFileWatcher.EnableRaisingEvents = $false } catch {}
        try { $script:sessionFileWatcher.Dispose() } catch {}
    }
    foreach ($overlay in @($script:overlaysByStrip.Values)) {
        try { $overlay.Window.Close() } catch {}
    }
}
