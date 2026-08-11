[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Reuse the version-specific Groupy record reader and verified physical detach implementation.
& (Join-Path $PSScriptRoot 'GroupyWindowShortcuts.ps1') -LoadRuntime

if (-not ('CodexGroupy.SeparateWindowHotkeyNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class SeparateWindowHotkeyNativeV1 {
        private const int MOD_CONTROL = 0x0002;
        private const int MOD_SHIFT = 0x0004;
        private const int HOTKEY_ID = 41;
        private const uint WM_HOTKEY = 0x0312;
        private const uint PM_REMOVE = 0x0001;
        private const byte VK_CONTROL = 0x11;
        private const byte VK_SHIFT = 0x10;
        private const byte VK_N = 0x4E;
        private const uint KEYEVENTF_KEYUP = 0x0002;

        [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; public uint lPrivate; }
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr hWnd, string lpString);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RegisterHotKey(IntPtr hWnd, int id, int modifiers, int virtualKey);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PeekMessage(out MSG message, IntPtr hWnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int virtualKey);
        [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        public static void Register() {
            if (!RegisterHotKey(IntPtr.Zero, HOTKEY_ID, MOD_CONTROL | MOD_SHIFT, VK_N)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not register Ctrl+Shift+N.");
        }
        public static void Unregister() { UnregisterHotKey(IntPtr.Zero, HOTKEY_ID); }
        public static bool TakeHotkey() {
            MSG msg;
            bool hit = false;
            while (PeekMessage(out msg, IntPtr.Zero, WM_HOTKEY, WM_HOTKEY, PM_REMOVE)) if (msg.wParam.ToInt32() == HOTKEY_ID) hit = true;
            return hit;
        }
        public static bool ModifiersAreDown() { return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 || (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0; }
        public static void SendCtrlN() {
            keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
            keybd_event(VK_N, 0, 0, UIntPtr.Zero);
            keybd_event(VK_N, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        }
        public static long[] VisibleCodeWindows() {
            var handles = new List<long>();
            EnumWindows((hWnd, unused) => {
                if (!IsWindowVisible(hWnd)) return true;
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                try { if (Process.GetProcessById((int)pid).ProcessName.Equals("Code", StringComparison.OrdinalIgnoreCase)) handles.Add(hWnd.ToInt64()); } catch { }
                return true;
            }, IntPtr.Zero);
            return handles.ToArray();
        }
    }
}
'@
}

function Get-GroupyTabInfo([IntPtr]$Window) {
    $strip = [CodexGroupy.SeparateWindowHotkeyNativeV1]::GetProp($Window, 'GP_LINK')
    if ($strip -eq [IntPtr]::Zero) { return $null }
    $controller = Get-Process GroupyCtrl -ErrorAction Stop | Select-Object -First 1
    $module = $controller.Modules | Where-Object { $_.ModuleName -eq 'GroupyCtrl.exe' } | Select-Object -First 1
    [int]$record = -1; [int]$member = -1
    $tabRect = [CodexGroupy.WindowShortcutNativeV2+RECT]::new()
    if (-not [CodexGroupy.WindowShortcutNativeV2]::TryReadTabRectangle([uint32]$controller.Id, $module.BaseAddress.ToInt64(), $strip, $Window, [ref]$record, [ref]$member, [ref]$tabRect)) { return $null }
    $clientRect = [CodexGroupy.WindowShortcutNativeV2+RECT]::new()
    if (-not [CodexGroupy.WindowShortcutNativeV2]::GetClientRect($strip, [ref]$clientRect)) { return $null }
    return [pscustomobject]@{ Window = $Window; Strip = $strip; Tab = $tabRect; Client = $clientRect }
}

function Invoke-DuplicateInSeparateGroup {
    $source = [CodexGroupy.SeparateWindowHotkeyNativeV1]::GetForegroundWindow()
    if (([CodexGroupy.SeparateWindowHotkeyNativeV1]::GetProp($source, 'GP_LINK')) -eq [IntPtr]::Zero) { return }
    $before = [System.Collections.Generic.HashSet[long]]::new([long[]]([CodexGroupy.SeparateWindowHotkeyNativeV1]::VisibleCodeWindows()))
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ([CodexGroupy.SeparateWindowHotkeyNativeV1]::ModifiersAreDown() -and $deadline.ElapsedMilliseconds -lt 600) { Start-Sleep -Milliseconds 10 }
    [CodexGroupy.SeparateWindowHotkeyNativeV1]::SendCtrlN()
    $deadline.Restart()
    while ($deadline.ElapsedMilliseconds -lt 8000) {
        foreach ($raw in [CodexGroupy.SeparateWindowHotkeyNativeV1]::VisibleCodeWindows()) {
            if ($before.Contains($raw)) { continue }
            $info = Get-GroupyTabInfo ([IntPtr]$raw)
            if ($info) {
                [CodexGroupy.WindowShortcutPhysicalV1]::DetachAndRestorePointer($info.Strip, $info.Tab.Left, $info.Tab.Top, $info.Tab.Right, $info.Tab.Bottom, $info.Client.Right, $info.Client.Bottom)
                Write-Host ("Ctrl+Shift+N: duplicated and separated VS Code window 0x{0:X}." -f $raw)
                return
            }
        }
        Start-Sleep -Milliseconds 25
    }
    Write-Warning 'VS Code duplicated, but the new window did not become a Groupy tab in time; it was left unchanged.'
}

[CodexGroupy.SeparateWindowHotkeyNativeV1]::Register()
try {
    Write-Host 'Ctrl+Shift+N now duplicates the current VS Code workspace into a separate Groupy group. Press Ctrl+C to stop.'
    while ($true) {
        if ([CodexGroupy.SeparateWindowHotkeyNativeV1]::TakeHotkey()) {
            try { Invoke-DuplicateInSeparateGroup } catch { Write-Warning $_.Exception.Message }
        }
        Start-Sleep -Milliseconds 25
    }
}
finally { [CodexGroupy.SeparateWindowHotkeyNativeV1]::Unregister() }
