[CmdletBinding()]
param(
    # Print the order Groupy is currently displaying, then exit.
    [switch]$Inspect,

    # The home/closed labels must match CodexGroupyTabSync.ps1 if you changed them there.
    [string]$CodexHomeTitle = 'Codex home',
    [string]$CodexClosedTitle = 'Codex closed',

    [ValidateRange(20, 1000)]
    [int]$RefreshDelayMs = 80
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This helper deliberately has no dependency on Groupy's rename dialog. Its default path reads
# GroupyCtrl's live ordered HWND array directly; the older Windows OCR path remains only as a
# compatibility fallback if that fixed-build native probe is unavailable.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -Path 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Runtime.WindowsRuntime.dll'
$null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType=WindowsRuntime]
$null = [Windows.Security.Cryptography.CryptographicBuffer, Windows.Security.Cryptography.Core, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]

if (-not ('CodexGroupy.NumberTabsNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public struct GroupMemberInfo {
        public long Handle;
        public uint ProcessId;
        public string Title;
    }

    public static class NumberTabsNativeV1 {
        private const int SW_RESTORE = 9;
        private const int MOD_CONTROL = 0x0002;
        private const uint WM_HOTKEY = 0x0312;
        private const int PM_REMOVE = 0x0001;
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }
        [StructLayout(LayoutKind.Sequential)]
        private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; public uint lPrivate; }
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr hWnd, string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetWindowText(IntPtr hWnd, string text);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr hWnd, int id, int modifiers, int virtualKey);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] private static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);

        public static IntPtr GetGroupLink(IntPtr hWnd) { return GetProp(hWnd, "GP_LINK"); }
        public static GroupMemberInfo[] GetGroupMembers(IntPtr link) {
            var members = new List<GroupMemberInfo>();
            EnumWindows((hWnd, _) => {
                if (GetProp(hWnd, "GP_LINK") != link) return true;
                var klass = new StringBuilder(128); GetClassName(hWnd, klass, klass.Capacity);
                if (klass.ToString() != "Chrome_WidgetWin_1") return true;
                uint processId; GetWindowThreadProcessId(hWnd, out processId);
                var title = new StringBuilder(2048); GetWindowText(hWnd, title, title.Capacity);
                members.Add(new GroupMemberInfo { Handle = hWnd.ToInt64(), ProcessId = processId, Title = title.ToString() });
                return true;
            }, IntPtr.Zero);
            return members.ToArray();
        }
        public static void Focus(long rawHandle) {
            var hWnd = new IntPtr(rawHandle);
            // Groupy's hidden background members are still normal, non-minimized windows. Calling
            // ShowWindow(SW_RESTORE) on every tab switch forced VS Code to redraw and caused a
            // visible flash. Only restore a genuinely minimized target.
            if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
            SetForegroundWindow(hWnd);
        }
        public static void RegisterNumberHotkeys() {
            for (int i = 1; i <= 9; i++) if (!RegisterHotKey(IntPtr.Zero, i, MOD_CONTROL, 0x30 + i)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not register Ctrl+" + i + ".");
        }
        public static void UnregisterNumberHotkeys() { for (int i = 1; i <= 9; i++) UnregisterHotKey(IntPtr.Zero, i); }
        public static int TakeNumberHotkey() {
            MSG message;
            return PeekMessage(out message, IntPtr.Zero, WM_HOTKEY, WM_HOTKEY, PM_REMOVE) ? message.wParam.ToInt32() : 0;
        }
    }
}
'@
}

# Reverse-engineered, version-specific reader for Groupy 2.3.1. The GroupyCtrl tab-strip
# procedure uses a fixed table of 2,000 group records. A record is selected by its strip HWND;
# its ordered member HWND array begins at +0x7040. This is read-only and has no UI side effects.
if (-not ('CodexGroupy.NumberTabsNativeV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class NumberTabsNativeV2 {
        private const int GroupCount = 0x7D0;
        private const int GroupRecordSize = 0x7CC0;
        private const int GroupTableRva = 0x196F30;
        private const int StripHandleOffset = 0x7BF0;
        private const int OrderedTabOffset = 0x7040;
        private const int OrderedTabCapacity = 53;
        private const uint ProcessQueryInformation = 0x0400;
        private const uint ProcessVmRead = 0x0010;
        private static readonly object CacheLock = new object();
        private static readonly Dictionary<string, int> GroupIndexCache = new Dictionary<string, int>();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, IntPtr size, out IntPtr bytesRead);
        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        public static string ReadWindowTitle(long rawHandle) {
            var title = new StringBuilder(2048);
            GetWindowText(new IntPtr(rawHandle), title, title.Capacity);
            return title.ToString();
        }

        private static byte[] ReadExact(IntPtr process, long address, int length) {
            var buffer = new byte[length];
            IntPtr bytesRead;
            if (!ReadProcessMemory(process, new IntPtr(address), buffer, (IntPtr)buffer.Length, out bytesRead) || bytesRead.ToInt64() != buffer.Length) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            return buffer;
        }

        private static long[] ReadTabArray(IntPtr process, long groupBase) {
            var data = ReadExact(process, groupBase + OrderedTabOffset, OrderedTabCapacity * 8);
            var tabs = new List<long>();
            for (var tabIndex = 0; tabIndex < OrderedTabCapacity; tabIndex++) {
                var hwnd = BitConverter.ToInt64(data, tabIndex * 8);
                if (hwnd == 0) break;
                tabs.Add(hwnd);
            }
            return tabs.ToArray();
        }

        public static long[] ReadOrderedTabHandles(uint groupyProcessId, long groupyModuleBase, long expectedStripHandle) {
            var process = OpenProcess(ProcessQueryInformation | ProcessVmRead, false, groupyProcessId);
            if (process == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try {
                var tableBase = groupyModuleBase + GroupTableRva;
                var cacheKey = groupyProcessId.ToString() + ":" + groupyModuleBase.ToString("X") + ":" + expectedStripHandle.ToString("X");
                int groupIndex = -1;
                lock (CacheLock) { GroupIndexCache.TryGetValue(cacheKey, out groupIndex); }

                // The cached record position is verified against the live strip handle before
                // use. Tab drags rewrite the array in that same record, so this stays exact.
                if (groupIndex >= 0) {
                    var groupBase = tableBase + ((long)groupIndex * GroupRecordSize);
                    var liveStrip = BitConverter.ToInt64(ReadExact(process, groupBase + StripHandleOffset, 8), 0);
                    if (liveStrip == expectedStripHandle) return ReadTabArray(process, groupBase);
                    lock (CacheLock) { GroupIndexCache.Remove(cacheKey); }
                }

                // First encounter: scan Groupy's table once to resolve the record. Subsequent
                // number-key presses read only 432 bytes (strip verification plus 53 HWNDs).
                var table = ReadExact(process, tableBase, GroupCount * GroupRecordSize);
                for (var candidateIndex = 0; candidateIndex < GroupCount; candidateIndex++) {
                    var groupOffset = candidateIndex * GroupRecordSize;
                    if (BitConverter.ToInt64(table, groupOffset + StripHandleOffset) != expectedStripHandle) continue;
                    lock (CacheLock) { GroupIndexCache[cacheKey] = candidateIndex; }
                    return ReadTabArray(process, tableBase + ((long)candidateIndex * GroupRecordSize));
                }
                return new long[0];
            } finally {
                CloseHandle(process);
            }
        }
    }
}
'@
}

function ConvertTo-GroupyTitle([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $clean = ($Title -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 117).TrimEnd() + '...' }
    return $clean
}

function Get-Descendants([System.Windows.Automation.AutomationElement]$Element) {
    @($Element) + @($Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
}

function Get-CodexTitleForCodeWindow([IntPtr]$Handle) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
    $all = Get-Descendants $root
    $document = $all | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and $_.Current.Name -eq 'Codex'
    } | ForEach-Object {
        $items = Get-Descendants $_
        if ($items.Current.Name -contains 'Chats' -or $items.Current.Name -contains 'New chat') { ,$items; break }
    } | Select-Object -First 1

    if ($document) {
        $header = $document | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
            -not [string]::IsNullOrWhiteSpace($_.Current.Name) -and
            $_.Current.ClassName -match 'flex-1\s+truncate' -and $_.Current.ClassName -match 'text-start'
        } | Select-Object -First 1
        if ($header) { return ConvertTo-GroupyTitle $header.Current.Name }
        return ConvertTo-GroupyTitle $CodexHomeTitle
    }

    $files = $all | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Tree -and $_.Current.Name -eq 'Files Explorer'
    } | Select-Object -First 1
    $workspace = $null
    if ($files) {
        $roots = @($files.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TreeItem)))
        if ($roots.Count -gt 0) { $workspace = ConvertTo-GroupyTitle $roots[0].Current.Name }
    }
    if ($workspace) { return ConvertTo-GroupyTitle "$workspace - $CodexClosedTitle" }
    return ConvertTo-GroupyTitle $CodexClosedTitle
}

function Get-StripOcrWords([CodexGroupy.NumberTabsNativeV1+RECT]$Rect) {
    $width = $Rect.Right - $Rect.Left; $height = $Rect.Bottom - $Rect.Top
    if ($width -le 0 -or $height -le 0) { return @() }
    $bitmap = New-Object Drawing.Bitmap($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy) } finally { $graphics.Dispose() }
    $lock = $bitmap.LockBits((New-Object Drawing.Rectangle(0, 0, $width, $height)), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try { $bytes = New-Object byte[] ($lock.Stride * $height); [Runtime.InteropServices.Marshal]::Copy($lock.Scan0, $bytes, 0, $bytes.Length) } finally { $bitmap.UnlockBits($lock); $bitmap.Dispose() }

    $buffer = [Windows.Security.Cryptography.CryptographicBuffer]::CreateFromByteArray([byte[]]$bytes)
    $copy = [Windows.Graphics.Imaging.SoftwareBitmap].GetMethods() | Where-Object { $_.Name -eq 'CreateCopyFromBuffer' -and $_.GetParameters().Count -eq 5 }
    $softwareBitmap = $copy.Invoke($null, [object[]]@($buffer, [Windows.Graphics.Imaging.BitmapPixelFormat]87, [int]$width, [int]$height, [Windows.Graphics.Imaging.BitmapAlphaMode]0))
    try {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        $operation = $engine.RecognizeAsync($softwareBitmap)
        $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1).MakeGenericMethod([Windows.Media.Ocr.OcrResult])
        $task = $asTask.Invoke($null, [object[]]@($operation)); $task.Wait()
        @($task.Result.Lines | ForEach-Object { $_.Words } | ForEach-Object { [pscustomobject]@{ Text = $_.Text; X = [double]$_.BoundingRect.X; Width = [double]$_.BoundingRect.Width } }) | Sort-Object X
    } finally { $softwareBitmap.Dispose() }
}

function Normalize-Word([string]$Text) { (($Text -replace '[^\p{L}\p{N}]', '').ToLowerInvariant()) }
function Test-WordMatch([string]$Left, [string]$Right) {
    $a = Normalize-Word $Left; $b = Normalize-Word $Right
    if (-not $a -or -not $b) { return $false }
    if ($a -eq $b) { return $true }
    # OCR very occasionally misses one character (for example, Groupy -> Goupy).
    if ([Math]::Abs($a.Length - $b.Length) -gt 1) { return $false }
    $i = 0; $j = 0; $mistakes = 0
    while ($i -lt $a.Length -and $j -lt $b.Length) { if ($a[$i] -eq $b[$j]) { $i++; $j++ } elseif (++$mistakes -gt 1) { return $false } elseif ($a.Length -gt $b.Length) { $i++ } elseif ($b.Length -gt $a.Length) { $j++ } else { $i++; $j++ } }
    return $true
}

$script:NativeGroupyController = $null
function Get-NativeGroupyOrder([IntPtr]$Link) {
    try {
        if (-not $script:NativeGroupyController) {
            $controller = Get-Process GroupyCtrl -ErrorAction Stop | Select-Object -First 1
            $module = $controller.Modules | Where-Object { $_.ModuleName -eq 'GroupyCtrl.exe' } | Select-Object -First 1
            if (-not $module) { return @() }
            $script:NativeGroupyController = [pscustomobject]@{
                Id = [uint32]$controller.Id
                ModuleBase = [Int64]$module.BaseAddress
            }
        }
        return @([CodexGroupy.NumberTabsNativeV2]::ReadOrderedTabHandles(
            $script:NativeGroupyController.Id,
            $script:NativeGroupyController.ModuleBase,
            [Int64]$Link.ToInt64()
        ))
    } catch {
        # A restarted GroupyCtrl receives a new PID/base address. Drop the cached location so
        # the next request can rediscover it, then fall back safely for this key press.
        $script:NativeGroupyController = $null
        return @()
    }
}

function Get-OrderedGroupMembers([IntPtr]$Link) {
    $nativeOrder = @(Get-NativeGroupyOrder $Link)
    if ($nativeOrder.Count -gt 0) {
        # The order is Groupy's own live ordered HWND array. No OCR, UI Automation, or title
        # matching occurs on this path; window captions are retained only for -Inspect output.
        return @($nativeOrder | ForEach-Object {
            [pscustomobject]@{
                IndexX = 0
                Handle = [IntPtr]$_
                Title = [CodexGroupy.NumberTabsNativeV2]::ReadWindowTitle($_)
            }
        })
    }

    $members = @([CodexGroupy.NumberTabsNativeV1]::GetGroupMembers($Link))
    if ($members.Count -eq 0) { return @() }

    # Refresh Code members silently so their native captions and Groupy's rendered captions agree.
    foreach ($member in $members) {
        try {
            $process = Get-Process -Id $member.ProcessId -ErrorAction Stop
            if ($process.ProcessName -in @('Code', 'Code - Insiders')) {
                $title = Get-CodexTitleForCodeWindow ([IntPtr]$member.Handle)
                if ($title) { [void][CodexGroupy.NumberTabsNativeV1]::SetWindowText([IntPtr]$member.Handle, $title); $member.Title = $title }
            }
        } catch { }
    }
    Start-Sleep -Milliseconds $RefreshDelayMs
    [CodexGroupy.NumberTabsNativeV1+RECT]$rect = [CodexGroupy.NumberTabsNativeV1+RECT]::new()
    if (-not [CodexGroupy.NumberTabsNativeV1]::GetWindowRect($Link, [ref]$rect)) { return @() }
    # Groupy's reported rectangle stops just above the anti-aliased text baseline on this version.
    # Include a small amount below it so Windows OCR sees the full caption glyphs.
    $rect.Bottom += 10
    $words = @(Get-StripOcrWords $rect)
    $resolved = foreach ($member in $members) {
        $tokens = @($member.Title -split '\s+' | Where-Object { (Normalize-Word $_).Length -ge 3 })
        $hits = @(for ($i = 0; $i -lt $words.Count; $i++) { if ($tokens.Count -gt 0 -and (Test-WordMatch $words[$i].Text $tokens[0])) { $i } })
        if ($hits.Count -ne 1) { continue }
        [pscustomobject]@{ IndexX = $words[$hits[0]].X; Handle = [IntPtr]$member.Handle; Title = $member.Title }
    }
    @($resolved | Sort-Object IndexX)
}

function Invoke-SelectGroupyTab([int]$Number) {
    $foreground = [CodexGroupy.NumberTabsNativeV1]::GetForegroundWindow()
    $link = [CodexGroupy.NumberTabsNativeV1]::GetGroupLink($foreground)
    if ($link -eq [IntPtr]::Zero) { return }
    # Fast path: no captions, PowerShell objects, UIA, or OCR are needed to select a live native
    # array entry. This is the path invoked by every Ctrl+number press.
    $nativeOrder = @(Get-NativeGroupyOrder $link)
    if ($nativeOrder.Count -gt 0) {
        if ($Number -le $nativeOrder.Count) { [CodexGroupy.NumberTabsNativeV1]::Focus([IntPtr]$nativeOrder[$Number - 1]) }
        return
    }
    $ordered = @(Get-OrderedGroupMembers $link)
    if ($Number -le $ordered.Count) { [CodexGroupy.NumberTabsNativeV1]::Focus($ordered[$Number - 1].Handle) }
}

if ($Inspect) {
    $foreground = [CodexGroupy.NumberTabsNativeV1]::GetForegroundWindow()
    $link = [CodexGroupy.NumberTabsNativeV1]::GetGroupLink($foreground)
    if ($link -eq [IntPtr]::Zero) { Write-Host 'The foreground window is not in a Groupy group.'; return }
    $rows = @(Get-OrderedGroupMembers $link)
    if ($rows.Count -eq 0) { Write-Host 'Could not map the Groupy tab captions to windows.'; return }
    $rows | ForEach-Object -Begin { $n = 0 } -Process { $n++; [pscustomobject]@{ Tab = $n; Handle = ('0x{0:X}' -f $_.Handle.ToInt64()); Title = $_.Title } } | Format-Table -AutoSize
    return
}

[CodexGroupy.NumberTabsNativeV1]::RegisterNumberHotkeys()
try {
    Write-Host 'Ctrl+1 through Ctrl+9 now select the corresponding visible Groupy tab. Press Ctrl+C to stop.'
    while ($true) {
        $number = [CodexGroupy.NumberTabsNativeV1]::TakeNumberHotkey()
        if ($number -gt 0) { Invoke-SelectGroupyTab $number }
        # A short PowerShell sleep gives Ctrl+C a normal console interruption point.
        Start-Sleep -Milliseconds 25
    }
} finally {
    [CodexGroupy.NumberTabsNativeV1]::UnregisterNumberHotkeys()
}
