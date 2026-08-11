[CmdletBinding()]
param(
    # Read the active Groupy tab's live rectangle and exit. This never changes a group.
    [switch]$InspectCurrent,

    # Read-only diagnostic for locating the active tab's stored Groupy fields.
    [switch]$DebugCurrent,

    # Load the native helpers for another script in this PowerShell process, then exit.
    [switch]$LoadRuntime,

    # Experimental and intentional: separate the active Groupy tab into a new one-tab group.
    # Use only to validate Groupy's own synthetic drag path before enabling a shortcut.
    [switch]$TestDetachCurrent,

    # Experimental and intentional: detach with real Windows pointer input, then restore the
    # pointer. This is required if Groupy rejects the no-cursor synthetic message sequence.
    [switch]$TestPhysicalDetachCurrent
)

$ErrorActionPreference = 'Stop'

if ((@($InspectCurrent, $DebugCurrent, $TestDetachCurrent, $TestPhysicalDetachCurrent) | Where-Object { $_ }).Count -gt 1) {
    throw 'Use only one mode at a time.'
}

if (-not ('CodexGroupy.WindowShortcutNativeV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class WindowShortcutNativeV2 {
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;
        private const int GroupCount = 0x7D0;
        private const int GroupRecordSize = 0x7CC0;
        private const int GroupTableRva = 0x196F30;
        private const int StripHandleOffset = 0x7BF0;
        private const int OrderedTabHandlesOffset = 0x7040;
        private const int OrderedTabCapacity = 53;
        private const int OrderedTabRectanglesOffset = 0x76E8;

        private const uint WM_LBUTTONDOWN = 0x0201;
        private const uint WM_MOUSEMOVE = 0x0200;
        private const uint WM_LBUTTONUP = 0x0202;
        private const uint MK_LBUTTON = 0x0001;

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr hWnd, string lpString);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, IntPtr size, out IntPtr bytesRead);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);

        private static bool ReadExact(IntPtr process, long address, byte[] buffer) {
            IntPtr read;
            return ReadProcessMemory(process, new IntPtr(address), buffer, new IntPtr(buffer.Length), out read) && read.ToInt64() == buffer.Length;
        }

        private static long ReadInt64(IntPtr process, long address) {
            byte[] buffer = new byte[8];
            if (!ReadExact(process, address, buffer)) throw new InvalidOperationException("ReadProcessMemory failed while locating the Groupy group record.");
            return BitConverter.ToInt64(buffer, 0);
        }

        public static bool TryReadTabRectangle(uint groupyPid, long moduleBase, IntPtr strip, IntPtr tab, out int recordIndex, out int memberIndex, out RECT rect) {
            recordIndex = -1;
            memberIndex = -1;
            rect = new RECT();
            IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, groupyPid);
            if (process == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not read GroupyCtrl.exe.");
            try {
                long table = moduleBase + GroupTableRva;
                for (int group = 0; group < GroupCount; group++) {
                    long record = table + ((long)group * GroupRecordSize);
                    if (ReadInt64(process, record + StripHandleOffset) != strip.ToInt64()) continue;
                    recordIndex = group;
                    for (int member = 0; member < OrderedTabCapacity; member++) {
                        if (ReadInt64(process, record + OrderedTabHandlesOffset + ((long)member * 8)) != tab.ToInt64()) continue;
                        byte[] rawRect = new byte[16];
                        if (!ReadExact(process, record + OrderedTabRectanglesOffset + ((long)member * 16), rawRect)) throw new InvalidOperationException("Could not read the Groupy tab rectangle.");
                        rect.Left = BitConverter.ToInt32(rawRect, 0);
                        rect.Top = BitConverter.ToInt32(rawRect, 4);
                        rect.Right = BitConverter.ToInt32(rawRect, 8);
                        rect.Bottom = BitConverter.ToInt32(rawRect, 12);
                        memberIndex = member;
                        return rect.Right > rect.Left && rect.Bottom > rect.Top;
                    }
                    return false;
                }
                return false;
            }
            finally { CloseHandle(process); }
        }

        private static IntPtr PackPoint(int x, int y) {
            long packed = ((long)(ushort)y << 16) | (ushort)x;
            return new IntPtr(packed);
        }

        // Delivers the same three pointer messages handled by Groupy's tab strip. The cursor is
        // not moved and no Groupy data is written directly; Groupy itself performs any detach.
        public static void DetachBySyntheticDrag(IntPtr strip, RECT tab, RECT client) {
            int startX = tab.Left + ((tab.Right - tab.Left) / 2);
            int startY = tab.Top + ((tab.Bottom - tab.Top) / 2);
            int endX = -Math.Max(120, client.Right / 2);
            int endY = Math.Max(client.Bottom + 120, 160);
            SendMessage(strip, WM_LBUTTONDOWN, new IntPtr(MK_LBUTTON), PackPoint(startX, startY));
            for (int step = 1; step <= 8; step++) {
                int x = startX + (((endX - startX) * step) / 8);
                int y = startY + (((endY - startY) * step) / 8);
                SendMessage(strip, WM_MOUSEMOVE, new IntPtr(MK_LBUTTON), PackPoint(x, y));
            }
            SendMessage(strip, WM_LBUTTONUP, IntPtr.Zero, PackPoint(endX, endY));
        }
    }
}
'@
}

if (($TestPhysicalDetachCurrent -or $LoadRuntime) -and -not ('CodexGroupy.WindowShortcutPhysicalV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace CodexGroupy {
    public static class WindowShortcutPhysicalV1 {
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out POINT point);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

        // This intentionally uses real pointer input because Groupy verifies the physical capture
        // state during a tab drag. The pointer is restored even if the interaction fails.
        public static void DetachAndRestorePointer(IntPtr strip, int left, int top, int right, int bottom, int clientWidth, int clientHeight) {
            POINT saved;
            RECT stripRect;
            if (!GetCursorPos(out saved)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not save the pointer position.");
            if (!GetWindowRect(strip, out stripRect)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not locate the Groupy tab strip.");
            int startX = stripRect.Left + left + ((right - left) / 2);
            int startY = stripRect.Top + top + ((bottom - top) / 2);
            int endX = stripRect.Left - Math.Max(120, clientWidth / 2);
            int endY = stripRect.Top + Math.Max(clientHeight + 120, 160);
            bool down = false;
            try {
                if (!SetCursorPos(startX, startY)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not position the pointer on the Groupy tab.");
                Thread.Sleep(15);
                mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
                down = true;
                Thread.Sleep(15);
                if (!SetCursorPos(endX, endY)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not move the pointer outside the Groupy tab strip.");
                Thread.Sleep(35);
                mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
                down = false;
            }
            finally {
                if (down) mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
                SetCursorPos(saved.X, saved.Y);
            }
        }
    }
}
'@
}

if ($LoadRuntime) { return }

$foreground = [CodexGroupy.WindowShortcutNativeV2]::GetForegroundWindow()
$strip = [CodexGroupy.WindowShortcutNativeV2]::GetProp($foreground, 'GP_LINK')
if ($strip -eq [IntPtr]::Zero) {
    throw 'Focus the intended VS Code Groupy tab (an integrated terminal is fine), then run this command again.'
}

$controller = Get-Process GroupyCtrl -ErrorAction Stop | Select-Object -First 1
$module = $controller.Modules | Where-Object { $_.ModuleName -eq 'GroupyCtrl.exe' } | Select-Object -First 1
if (-not $module) { throw 'Could not resolve the loaded GroupyCtrl.exe module.' }

[int]$record = -1
[int]$member = -1
$tabRect = [CodexGroupy.WindowShortcutNativeV2+RECT]::new()
$mappedTabRectangle = [CodexGroupy.WindowShortcutNativeV2]::TryReadTabRectangle([uint32]$controller.Id, $module.BaseAddress.ToInt64(), $strip, $foreground, [ref]$record, [ref]$member, [ref]$tabRect)
if (-not $mappedTabRectangle -and -not $DebugCurrent) {
    throw 'Could not map the active window to a live Groupy tab rectangle. No action was taken.'
}

if ($DebugCurrent) {
    if (-not ('CodexGroupy.WindowShortcutDiagnosticV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class WindowShortcutDiagnosticV1 {
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;
        private const int GroupRecordSize = 0x7CC0;
        private const int GroupTableRva = 0x196F30;
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, IntPtr size, out IntPtr bytesRead);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
        public static int[] FindHandleOffsets(uint processId, long moduleBase, int recordIndex, long handle) {
            IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
            if (process == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not read GroupyCtrl.exe.");
            try {
                byte[] record = new byte[GroupRecordSize];
                IntPtr read;
                long address = moduleBase + GroupTableRva + ((long)recordIndex * GroupRecordSize);
                if (!ReadProcessMemory(process, new IntPtr(address), record, new IntPtr(record.Length), out read) || read.ToInt64() != record.Length) throw new InvalidOperationException("Could not read the Groupy group record.");
                var offsets = new List<int>();
                for (int offset = 0; offset <= record.Length - 8; offset += 8) if (BitConverter.ToInt64(record, offset) == handle) offsets.Add(offset);
                return offsets.ToArray();
            }
            finally { CloseHandle(process); }
        }
    }
}
'@
    }
    if ($record -lt 0) { throw 'The matching Groupy group record could not be located.' }
    $offsets = [CodexGroupy.WindowShortcutDiagnosticV1]::FindHandleOffsets([uint32]$controller.Id, $module.BaseAddress.ToInt64(), $record, $foreground.ToInt64())
    Write-Host ("Active window: 0x{0:X}; Groupy strip: 0x{1:X}; record {2}" -f $foreground.ToInt64(), $strip.ToInt64(), $record)
    if ($offsets.Count -eq 0) { Write-Host 'The active window handle was not present as an aligned 64-bit value anywhere in this record.' }
    else { Write-Host ('Active window handle occurs at record offsets: ' + (($offsets | ForEach-Object { '0x{0:X}' -f $_ }) -join ', ')) }
    return
}

if ($record -lt 0 -or $member -lt 0) {
    throw 'Could not map the active window to a live Groupy tab rectangle. No action was taken.'
}

$clientRect = [CodexGroupy.WindowShortcutNativeV2+RECT]::new()
if (-not [CodexGroupy.WindowShortcutNativeV2]::GetClientRect($strip, [ref]$clientRect)) {
    throw 'Could not read the Groupy tab-strip client rectangle.'
}

Write-Host ("Active window: 0x{0:X}; Groupy strip: 0x{1:X}; record {2}; member slot {3}" -f $foreground.ToInt64(), $strip.ToInt64(), $record, $member)
Write-Host ("Active tab rectangle: left={0}, top={1}, right={2}, bottom={3}" -f $tabRect.Left, $tabRect.Top, $tabRect.Right, $tabRect.Bottom)

if ($InspectCurrent -or (-not $TestDetachCurrent -and -not $TestPhysicalDetachCurrent)) { return }

if ($TestPhysicalDetachCurrent) {
    Write-Host 'Sending a brief real-pointer Groupy drag, then restoring the pointer...'
    [CodexGroupy.WindowShortcutPhysicalV1]::DetachAndRestorePointer($strip, $tabRect.Left, $tabRect.Top, $tabRect.Right, $tabRect.Bottom, $clientRect.Right, $clientRect.Bottom)
    Write-Host 'Pointer restored. Check whether Groupy moved the active VS Code tab into its own one-tab group.'
}
else {
    Write-Host 'Sending Groupy the synthetic drag sequence for this active tab...'
    [CodexGroupy.WindowShortcutNativeV2]::DetachBySyntheticDrag($strip, $tabRect, $clientRect)
    Write-Host 'Sequence sent. Check whether Groupy moved the active VS Code tab into its own one-tab group.'
}
