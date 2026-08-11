[CmdletBinding()]
param(
    [ValidateRange(15, 900)]
    [int]$RefreshSeconds = 60,

    # Visual breathing room at the far right of the Groupy strip.
    [ValidateRange(0, 600)]
    [int]$RightMarginPixels = 16,

    # Useful for a quick visual check without leaving the helper running.
    [ValidateRange(0, 3600)]
    [int]$TestSeconds = 0,

    # Print why the active window can or cannot resolve a Codex context value, then exit.
    [switch]$InspectContext
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this helper with Windows PowerShell (powershell.exe), which uses STA for the transparent overlay window.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('CodexGroupy.UsageOverlayNativeV5' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexGroupy {
    public static class UsageOverlayNativeV5 {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
        public delegate void WinEventDelegate(IntPtr hook, uint eventType, IntPtr hWnd, int objectId, int childId, uint eventThread, uint eventTime);
        private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        private const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A;
        private const uint EVENT_SYSTEM_MOVESIZEEND = 0x000B;
        private const uint WINEVENT_OUTOFCONTEXT = 0;
        private static readonly ConcurrentDictionary<IntPtr, byte> MovingCodeWindows = new ConcurrentDictionary<IntPtr, byte>();
        private static readonly ConcurrentDictionary<uint, string> ProcessNameById = new ConcurrentDictionary<uint, string>();
        private static readonly WinEventDelegate MoveSizeCallback = OnMoveSizeEvent;
        private static long ForegroundGeneration;
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr hWnd, string lpString);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate callback, uint processId, uint threadId, uint flags);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool UnhookWinEvent(IntPtr hook);
        public static bool IsCodeWindow(IntPtr hWnd) {
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            try {
                string name = ProcessNameById.GetOrAdd(pid, id => Process.GetProcessById((int)id).ProcessName);
                return name.Equals("Code", StringComparison.OrdinalIgnoreCase) || name.Equals("Code - Insiders", StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
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
            if (eventType == EVENT_SYSTEM_FOREGROUND) { System.Threading.Interlocked.Increment(ref ForegroundGeneration); return; }
            IntPtr codeWindow = ResolveMoveTarget(hWnd);
            if (codeWindow == IntPtr.Zero) return;
            if (eventType == EVENT_SYSTEM_MOVESIZESTART) MovingCodeWindows[codeWindow] = 0;
            else if (eventType == EVENT_SYSTEM_MOVESIZEEND) { byte ignored; MovingCodeWindows.TryRemove(codeWindow, out ignored); }
        }
        public static IntPtr StartMoveSizeHook() {
            return SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND, IntPtr.Zero, MoveSizeCallback, 0, 0, WINEVENT_OUTOFCONTEXT);
        }
        public static IntPtr StartForegroundHook() {
            return SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, MoveSizeCallback, 0, 0, WINEVENT_OUTOFCONTEXT);
        }
        public static bool IsAnyMoveSizeActive() { return !MovingCodeWindows.IsEmpty; }
        public static bool IsMoveSizeActive(IntPtr hWnd) { return MovingCodeWindows.ContainsKey(hWnd); }
        public static long GetForegroundGeneration() { return System.Threading.Interlocked.Read(ref ForegroundGeneration); }
    }
}
'@
}

$window = [System.Windows.Window]::new()
$window.Width = 430
$window.Height = 29
$window.WindowStyle = 'None'
$window.ResizeMode = 'NoResize'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Focusable = $false

$panel = [System.Windows.Controls.Grid]::new()
$overlayForeground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(220, 220, 220))
$idleForeground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(245, 245, 245))
$workingForeground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(255, 205, 20))
$finishedForeground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(67, 201, 109))

$badgeText = [System.Windows.Controls.TextBlock]::new()
$badgeText.Text = 'loading...'
$badgeText.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
$badgeText.FontSize = 12
$badgeText.FontWeight = 'Normal'
$badgeText.Foreground = $overlayForeground
$badgeText.VerticalAlignment = 'Center'
$badgeText.HorizontalAlignment = 'Right'
$badgeText.TextAlignment = 'Right'
[void]$panel.Children.Add($badgeText)
$window.Content = $panel

$window.Add_SourceInitialized({
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    $style = [CodexGroupy.UsageOverlayNativeV5]::GetWindowLongPtr($handle, -20).ToInt64()
    # Transparent + no-activate makes this a visual badge only: it never captures clicks or focus.
    $style = $style -bor 0x20 -bor 0x80 -bor 0x08000000
    [void][CodexGroupy.UsageOverlayNativeV5]::SetWindowLongPtr($handle, -20, [IntPtr]$style)
})

$usageScript = Join-Path $PSScriptRoot 'Get-CodexUsage.ps1'
$activitySummaryPath = Join-Path $repoRoot 'work\ActivityDotsSummary.json'
$sessionIndexPath = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
$sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
$script:usageLabel = 'loading...'
$script:contextLabel = $null
$script:activityLabel = $null
$script:contextCache = @{}

function ConvertTo-CodexTitleKey([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $clean = ($Title -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    # Must match the watcher, which caps the window caption before Groupy sees it.
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 117).TrimEnd() + '...' }
    return $clean
}

function Get-CodexActiveTitleFromWindow([IntPtr]$Handle) {
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
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
        if (-not $document) { return $null }

        $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button
        )
        $buttons = $document.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
        foreach ($button in $buttons) {
            if ([string]::IsNullOrWhiteSpace($button.Current.Name)) { continue }
            if ($button.Current.ClassName -match 'flex-1\s+truncate' -and $button.Current.ClassName -match 'text-start') {
                return ConvertTo-CodexTitleKey $button.Current.Name
            }
        }
    }
    catch {
        # UIA can temporarily deny access while VS Code is rebuilding its webview. Treat that as no chat.
    }
    return $null
}

function Find-CodexSessionLog([string]$TitleKey) {
    if (-not $TitleKey -or -not (Test-Path -LiteralPath $sessionIndexPath)) { return $null }

    $matchesById = @{}
    foreach ($line in Get-Content -LiteralPath $sessionIndexPath) {
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $entry.PSObject.Properties['thread_name']) { continue }
        if ((ConvertTo-CodexTitleKey $entry.thread_name) -ne $TitleKey -or -not $entry.id) { continue }
        $matchesById[$entry.id] = $entry
    }
    # Refuse to guess when two separate chats share a title.
    if ($matchesById.Count -ne 1) { return $null }

    $sessionId = @($matchesById.Keys)[0]
    $candidate = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter "*$sessionId.jsonl" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Get-CodexContextCacheEntry([IntPtr]$Handle) {
    $key = $Handle.ToInt64().ToString('X')
    if (-not $script:contextCache.ContainsKey($key)) {
        $script:contextCache[$key] = @{
            NativeCaption = $null
            TitleKey = $null
            LogPath = $null
            LastWriteTicks = -1
            Label = $null
        }
    }
    return $script:contextCache[$key]
}

function Get-ActivitySummaryForActiveStrip([IntPtr]$Foreground, [IntPtr]$Strip) {
    if ($Strip -eq [IntPtr]::Zero -or -not (Test-Path -LiteralPath $activitySummaryPath)) { return $null }
    try {
        $item = Get-Item -LiteralPath $activitySummaryPath -ErrorAction Stop
        if (((Get-Date) - $item.LastWriteTime).TotalSeconds -gt 10) { return $null }
        $summary = Get-Content -LiteralPath $activitySummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($summary.allVisible) { return $summary.allVisible }
        return $null
    }
    catch {
        return $null
    }
}

function Get-CachedCodexContextLabel([IntPtr]$Handle) {
    $key = $Handle.ToInt64().ToString('X')
    if ($script:contextCache.ContainsKey($key)) { return $script:contextCache[$key].Label }
    return $null
}

function Get-CodexContextLabel([IntPtr]$Handle, [switch]$AllowUiAutomation) {
    $entry = Get-CodexContextCacheEntry $Handle
    $nativeCaption = [CodexGroupy.UsageOverlayNativeV5]::ReadWindowTitle($Handle)
    $nativeTitleKey = ConvertTo-CodexTitleKey $nativeCaption
    $captionChanged = ($entry.NativeCaption -ne $nativeCaption)
    if ($captionChanged) {
        $entry.NativeCaption = $nativeCaption
        $entry.TitleKey = $nativeTitleKey
        $entry.LogPath = if ($nativeTitleKey) { Find-CodexSessionLog $nativeTitleKey } else { $null }
        $entry.LastWriteTicks = -1
        $entry.Label = $null
    }

    # When the title watcher is not currently owning the native caption, read the selected Codex header directly.
    if (-not $entry.LogPath -and $AllowUiAutomation) {
        $uiaTitleKey = Get-CodexActiveTitleFromWindow $Handle
        if ($uiaTitleKey -and $entry.TitleKey -ne $uiaTitleKey) {
            $entry.TitleKey = $uiaTitleKey
            $entry.LogPath = Find-CodexSessionLog $uiaTitleKey
            $entry.LastWriteTicks = -1
            $entry.Label = $null
        }
    }

    if (-not $entry.TitleKey -or -not $entry.LogPath) { return $null }

    if ($AllowUiAutomation -and $entry.TitleKey -ne $nativeTitleKey -and -not $captionChanged) {
        # Keep checking the visible Codex header on windows whose native caption belongs to VS Code.
        $uiaTitleKey = Get-CodexActiveTitleFromWindow $Handle
        if ($uiaTitleKey -and $entry.TitleKey -ne $uiaTitleKey) {
            $entry.TitleKey = $uiaTitleKey
            $entry.LogPath = Find-CodexSessionLog $uiaTitleKey
            $entry.LastWriteTicks = -1
            $entry.Label = $null
        }
    }

    if (-not $entry.LogPath -or -not (Test-Path -LiteralPath $entry.LogPath)) { return $null }

    $logItem = Get-Item -LiteralPath $entry.LogPath
    $writeTicks = $logItem.LastWriteTimeUtc.Ticks
    if ($entry.LastWriteTicks -eq $writeTicks) { return $entry.Label }

    $latest = $null
    # Logs can contain very large tool-output records. Only parse the compact records that can hold usage.
    foreach ($line in Get-Content -LiteralPath $entry.LogPath -Tail 120) {
        if ($line -notmatch '"type":"token_count"') { continue }
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count' -and $event.payload.info.last_token_usage -and $event.payload.info.model_context_window) {
            $latest = $event.payload.info
        }
    }
    $entry.LastWriteTicks = $writeTicks
    if (-not $latest) { return $null }

    $windowTokens = [double]$latest.model_context_window
    $usedTokens = [double]$latest.last_token_usage.total_tokens
    if ($windowTokens -le 0 -or $usedTokens -lt 0) { return $null }
    $percentFull = [Math]::Max(0, [Math]::Min(100, [Math]::Round(100 * ($usedTokens / $windowTokens))))
    $percentLeft = [Math]::Max(0, [Math]::Min(100, 100 - $percentFull))
    $entry.Label = "Context $percentLeft% left"
    return $entry.Label
}

function Set-ActivityTextRuns([object]$Summary) {
    $badgeText.Inlines.Clear()
    if (-not $Summary) { return }
    $dot = [string][char]0x25CF
    $thinSpace = [string][char]0x2009

    $prefix = [System.Windows.Documents.Run]::new('Codex  ')
    $prefix.Foreground = $overlayForeground
    [void]$badgeText.Inlines.Add($prefix)

    $idleRun = [System.Windows.Documents.Run]::new("$dot$thinSpace$([int]$Summary.idle)   ")
    $idleRun.Foreground = $idleForeground
    [void]$badgeText.Inlines.Add($idleRun)

    $workingRun = [System.Windows.Documents.Run]::new("$dot$thinSpace$([int]$Summary.working)   ")
    $workingRun.Foreground = $workingForeground
    [void]$badgeText.Inlines.Add($workingRun)

    $finishedRun = [System.Windows.Documents.Run]::new("$dot$thinSpace$([int]$Summary.finished)")
    $finishedRun.Foreground = $finishedForeground
    [void]$badgeText.Inlines.Add($finishedRun)
}

function Update-OverlayText {
    Set-ActivityTextRuns $script:activityLabel
    $usageLabel = if ($script:contextLabel) { "$script:contextLabel  |  Weekly $script:usageLabel" } else { "Weekly $script:usageLabel" }
    if ($script:activityLabel) {
        $spacer = [System.Windows.Documents.Run]::new('        ')
        $spacer.Foreground = $overlayForeground
        [void]$badgeText.Inlines.Add($spacer)
    }
    $usageRun = [System.Windows.Documents.Run]::new($usageLabel)
    $usageRun.Foreground = $overlayForeground
    [void]$badgeText.Inlines.Add($usageRun)
}

function Update-UsageText {
    try {
        $usage = & $usageScript
        $timeRemaining = $usage.Reset - (Get-Date)
        $daysLabel = if ($timeRemaining.TotalSeconds -le 0) {
            'now'
        }
        elseif ($timeRemaining.TotalDays -lt 1) {
            '<1d'
        }
        else {
            ('{0}d' -f [Math]::Ceiling($timeRemaining.TotalDays))
        }
        $percentLeft = [Math]::Round(100 - [double]$usage.UsedPercent)
        $script:usageLabel = "$percentLeft%  $([char]0x00B7)  $daysLabel"
        $badgeText.Foreground = $overlayForeground
    }
    catch {
        $script:usageLabel = 'unavailable'
        $badgeText.Foreground = [System.Windows.Media.Brushes]::LightGray
    }
    Update-OverlayText
}

function Update-ContextText {
    if ([CodexGroupy.UsageOverlayNativeV5]::IsAnyMoveSizeActive()) { return }
    $foreground = [CodexGroupy.UsageOverlayNativeV5]::GetForegroundWindow()
    $strip = [CodexGroupy.UsageOverlayNativeV5]::GetProp($foreground, 'GP_LINK')
    if ($strip -eq [IntPtr]::Zero -or -not [CodexGroupy.UsageOverlayNativeV5]::IsCodeWindow($foreground)) {
        $script:contextLabel = $null
        $script:activityLabel = $null
    }
    else {
        $script:contextLabel = Get-CodexContextLabel $foreground -AllowUiAutomation
        $script:activityLabel = Get-ActivitySummaryForActiveStrip $foreground $strip
    }
    Update-OverlayText
}

function Warm-CurrentGroupyContextCache {
    if ([CodexGroupy.UsageOverlayNativeV5]::IsAnyMoveSizeActive()) { return }
    $foreground = [CodexGroupy.UsageOverlayNativeV5]::GetForegroundWindow()
    if (-not [CodexGroupy.UsageOverlayNativeV5]::IsCodeWindow($foreground)) { return }
    $activeStrip = [CodexGroupy.UsageOverlayNativeV5]::GetProp($foreground, 'GP_LINK')
    if ($activeStrip -eq [IntPtr]::Zero) { return }

    # Cache only the windows in the currently visible Groupy group; do not wake or focus them.
    foreach ($process in Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('Code', 'Code - Insiders') -and $_.MainWindowHandle -ne 0
    }) {
        $handle = [IntPtr]$process.MainWindowHandle
        if ([CodexGroupy.UsageOverlayNativeV5]::GetProp($handle, 'GP_LINK') -ne $activeStrip) { continue }
        [void](Get-CodexContextLabel $handle)
    }
}

function Write-ContextInspection {
    $foreground = [CodexGroupy.UsageOverlayNativeV5]::GetForegroundWindow()
    $isCode = [CodexGroupy.UsageOverlayNativeV5]::IsCodeWindow($foreground)
    $strip = if ($isCode) { [CodexGroupy.UsageOverlayNativeV5]::GetProp($foreground, 'GP_LINK') } else { [IntPtr]::Zero }
    $nativeTitle = if ($isCode) { [CodexGroupy.UsageOverlayNativeV5]::ReadWindowTitle($foreground) } else { $null }
    $titleKey = ConvertTo-CodexTitleKey $nativeTitle
    $context = if ($isCode -and $strip -ne [IntPtr]::Zero) { Get-CodexContextLabel $foreground -AllowUiAutomation } else { $null }
    $cacheEntry = if ($isCode) { Get-CodexContextCacheEntry $foreground } else { $null }
    [pscustomobject]@{
        ActiveHwnd = if ($foreground -eq [IntPtr]::Zero) { '<none>' } else { '0x{0:X}' -f $foreground.ToInt64() }
        IsVSCode = $isCode
        HasGroupyLink = ($strip -ne [IntPtr]::Zero)
        NativeWindowTitle = $nativeTitle
        SessionTitleKey = $titleKey
        MatchedSessionLog = if ($cacheEntry) { $cacheEntry.LogPath } else { $null }
        ContextLabel = if ($context) { $context } else { '<not resolved>' }
    } | Format-List
}

if ($InspectContext) {
    Write-ContextInspection
    return
}

function Update-OverlayPlacement {
    if ([CodexGroupy.UsageOverlayNativeV5]::IsAnyMoveSizeActive()) {
        if ($window.IsVisible) { $window.Hide() }
        return
    }
    $foreground = [CodexGroupy.UsageOverlayNativeV5]::GetForegroundWindow()
    $strip = [CodexGroupy.UsageOverlayNativeV5]::GetProp($foreground, 'GP_LINK')
    if ($strip -eq [IntPtr]::Zero -or -not [CodexGroupy.UsageOverlayNativeV5]::IsCodeWindow($foreground) -or [CodexGroupy.UsageOverlayNativeV5]::IsMoveSizeActive($foreground)) {
        if ($window.IsVisible) { $window.Hide() }
        return
    }
    $stripRect = [CodexGroupy.UsageOverlayNativeV5+RECT]::new()
    if (-not [CodexGroupy.UsageOverlayNativeV5]::GetWindowRect($strip, [ref]$stripRect)) {
        if ($window.IsVisible) { $window.Hide() }
        return
    }
    $source = [System.Windows.PresentationSource]::FromVisual($window)
    $toDeviceX = if ($source) { $source.CompositionTarget.TransformToDevice.M11 } else { 1.0 }
    $toDeviceY = if ($source) { $source.CompositionTarget.TransformToDevice.M22 } else { 1.0 }
    $widthPixels = $window.ActualWidth * $toDeviceX
    $heightPixels = $window.ActualHeight * $toDeviceY
    $x = $stripRect.Right - $RightMarginPixels - $widthPixels
    $y = $stripRect.Top + ((($stripRect.Bottom - $stripRect.Top) - $heightPixels) / 2)
    $fromDevice = if ($source) { $source.CompositionTarget.TransformFromDevice } else { [System.Windows.Media.Matrix]::Identity }
    $point = $fromDevice.Transform([System.Windows.Point]::new($x, $y))
    $window.Left = $point.X
    $window.Top = $point.Y
    if (-not $window.IsVisible) { $window.Show() }
}

$lastForegroundGeneration = -1
function Update-ContextOnForegroundChange {
    if ([CodexGroupy.UsageOverlayNativeV5]::IsAnyMoveSizeActive()) { return }
    $generation = [CodexGroupy.UsageOverlayNativeV5]::GetForegroundGeneration()
    if ($generation -eq $script:lastForegroundGeneration) { return }
    $script:lastForegroundGeneration = $generation
    $foreground = [CodexGroupy.UsageOverlayNativeV5]::GetForegroundWindow()
    $strip = [CodexGroupy.UsageOverlayNativeV5]::GetProp($foreground, 'GP_LINK')
    $script:contextLabel = if ($strip -ne [IntPtr]::Zero -and [CodexGroupy.UsageOverlayNativeV5]::IsCodeWindow($foreground)) {
        Get-CachedCodexContextLabel $foreground
    }
    else {
        $null
    }
    $script:activityLabel = if ($strip -ne [IntPtr]::Zero -and [CodexGroupy.UsageOverlayNativeV5]::IsCodeWindow($foreground)) {
        Get-ActivitySummaryForActiveStrip $foreground $strip
    }
    else {
        $null
    }
    Update-OverlayText
}

$positionTimer = [System.Windows.Threading.DispatcherTimer]::new()
$positionTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$positionTimer.Add_Tick({
    Update-OverlayPlacement
    Update-ContextOnForegroundChange
})

$usageTimer = [System.Windows.Threading.DispatcherTimer]::new()
$usageTimer.Interval = [TimeSpan]::FromSeconds($RefreshSeconds)
$usageTimer.Add_Tick({ Update-UsageText })

$contextTimer = [System.Windows.Threading.DispatcherTimer]::new()
$contextTimer.Interval = [TimeSpan]::FromSeconds(8)
$contextTimer.Add_Tick({ Update-ContextText })

$cacheWarmTimer = [System.Windows.Threading.DispatcherTimer]::new()
$cacheWarmTimer.Interval = [TimeSpan]::FromSeconds(30)
$cacheWarmTimer.Add_Tick({ Warm-CurrentGroupyContextCache })

$moveSizeHook = [CodexGroupy.UsageOverlayNativeV5]::StartMoveSizeHook()
if ($moveSizeHook -eq [IntPtr]::Zero) {
    Write-Warning 'Could not install the native move/resize event hook; the usage badge will still work but will follow window drags.'
}
$foregroundHook = [CodexGroupy.UsageOverlayNativeV5]::StartForegroundHook()
if ($foregroundHook -eq [IntPtr]::Zero) {
    Write-Warning 'Could not install the native foreground event hook; chat-context updates will wait for the normal two-second refresh.'
}

Update-UsageText
Update-ContextText
Warm-CurrentGroupyContextCache
$window.Show()
$window.Hide()
Update-OverlayPlacement
$positionTimer.Start()
$usageTimer.Start()
$contextTimer.Start()
$cacheWarmTimer.Start()
Write-Host "Showing Codex weekly and active-chat context usage on the active Groupy / VS Code tab strip. Press Ctrl+C to stop."

$dispatcherFrame = [System.Windows.Threading.DispatcherFrame]::new()
$testTimer = $null
if ($TestSeconds -gt 0) {
    $testTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $testTimer.Interval = [TimeSpan]::FromSeconds($TestSeconds)
    $testTimer.Add_Tick({
        $testTimer.Stop()
        # Leave the PowerShell process' WPF dispatcher usable for a later normal run.
        $dispatcherFrame.Continue = $false
    })
    $testTimer.Start()
}

try {
    [System.Windows.Threading.Dispatcher]::PushFrame($dispatcherFrame)
}
finally {
    $positionTimer.Stop()
    $usageTimer.Stop()
    $contextTimer.Stop()
    $cacheWarmTimer.Stop()
    if ($testTimer) { $testTimer.Stop() }
    if ($moveSizeHook -ne [IntPtr]::Zero) {
        [void][CodexGroupy.UsageOverlayNativeV5]::UnhookWinEvent($moveSizeHook)
    }
    if ($foregroundHook -ne [IntPtr]::Zero) {
        [void][CodexGroupy.UsageOverlayNativeV5]::UnhookWinEvent($foregroundHook)
    }
    $window.Close()
}
