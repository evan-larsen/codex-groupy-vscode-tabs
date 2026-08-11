[CmdletBinding()]
param(
    [ValidateRange(10, 300)]
    [int]$DurationSeconds = 45
)

$ErrorActionPreference = 'Stop'

$traceLog = Join-Path $PSScriptRoot 'work\GroupyLinkTrace.log'
if (Test-Path -LiteralPath $traceLog) {
    $archive = Join-Path $PSScriptRoot ("work\GroupyLinkTrace-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $traceLog -Destination $archive
    Write-Host "Previous trace preserved as $archive"
}

if (-not ('CodexGroupy.DetachTraceNativeV2' -as [type])) {
    $traceDll = Join-Path $PSScriptRoot 'work\GroupyLinkTraceV2.dll'
    if (-not (Test-Path -LiteralPath $traceDll)) {
        throw "Missing trace DLL: $traceDll. Build GroupyLinkTrace.cpp before running this helper."
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class DetachTraceNativeV2 {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr hWnd, string lpString);
        [DllImport("user32.dll", SetLastError = true)] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport(@"$traceDll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool InstallLinkTrace(uint threadId);
        [DllImport(@"$traceDll")] public static extern void RemoveLinkTrace();
    }
}
"@ -ReferencedAssemblies 'System.Runtime.InteropServices'
}

$foreground = [CodexGroupy.DetachTraceNativeV2]::GetForegroundWindow()
$link = [CodexGroupy.DetachTraceNativeV2]::GetProp($foreground, 'GP_LINK')
if ($link -eq [IntPtr]::Zero) {
    throw 'Focus a VS Code window that is currently in the Groupy group you want to trace, then run this command again.'
}

[uint32]$groupyPid = 0
$threadId = [CodexGroupy.DetachTraceNativeV2]::GetWindowThreadProcessId($link, [ref]$groupyPid)
if ($threadId -eq 0 -or $groupyPid -eq 0) {
    throw 'Could not resolve the Groupy tab-strip thread.'
}

if (-not [CodexGroupy.DetachTraceNativeV2]::InstallLinkTrace($threadId)) {
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "Could not install the read-only Groupy trace (Win32 error $errorCode)."
}

try {
    Write-Host "Tracing Groupy tab-strip 0x$('{0:X}' -f $link.ToInt64()) for $DurationSeconds seconds."
    Write-Host 'Now manually drag one Groupy tab out of its group and release it to create a separate group.'
    Write-Host 'This helper only records messages; it does not move or change any windows.'
    Start-Sleep -Seconds $DurationSeconds
}
finally {
    [CodexGroupy.DetachTraceNativeV2]::RemoveLinkTrace()
    Write-Host 'Trace removed. The newest entries are in work\GroupyLinkTrace.log.'
}
