[CmdletBinding()]
param(
    # Groupy's configured "Rename current tab" shortcut.  Configure the same shortcut in Groupy 2.
    [string]$RenameHotkey = '^%+{F2}',

    # Only inspect and print the active Codex title; never send input to Groupy.
    [switch]$Inspect,

    # Rename the current Groupy tab to a hardcoded value.  Use this to prove Groupy automation first.
    [switch]$TestRename,

    # Experimental: change the active VS Code window caption without invoking Groupy's rename dialog.
    [switch]$TestNativeTitle,

    [string]$TestTitle = 'TEST CODEX TAB',

    # Continuously synchronize the foreground VS Code window.
    [switch]$Watch,

    # No-dialog mode for fresh Groupy tabs that still follow their application's window title.
    # Do not use this on a Groupy tab that has been manually renamed.
    [switch]$WatchAutoTitle,

    # Labels used only by -WatchAutoTitle when no existing Codex conversation is selected.
    [string]$CodexHomeTitle = 'Codex home',
    [string]$CodexClosedTitle = 'Codex closed',

    # Experimental: install a thread-local native CBT hook inside Groupy while each rename runs.
    # This is more invasive than the default external dialog handler, but can prevent the dialog
    # from activating at all on this fixed Groupy version.
    [switch]$UseInProcessNoFlashHook,

    [ValidateRange(50, 10000)]
    [int]$PollIntervalMs = 100,

    [ValidateRange(20, 3000)]
    [int]$RenameDialogDelayMs = 50,

    # Useful for -TestRename: lets you switch from the terminal back to the intended VS Code tab.
    [ValidateRange(0, 30)]
    [int]$StartDelaySeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('CodexGroupy.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class Native {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsHungAppWindow(IntPtr hWnd);

        private static readonly ConcurrentDictionary<uint, string> ProcessNameById = new ConcurrentDictionary<uint, string>();

        public static bool IsCodeWindow(IntPtr hWnd) {
            uint processId; GetWindowThreadProcessId(hWnd, out processId);
            try {
                string name = ProcessNameById.GetOrAdd(processId, id => Process.GetProcessById((int)id).ProcessName);
                return name.Equals("Code", StringComparison.OrdinalIgnoreCase) || name.Equals("Code - Insiders", StringComparison.OrdinalIgnoreCase);
            } catch { return false; }
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        private const int INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint KEYEVENTF_UNICODE = 0x0004;

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT {
            public int type;
            public InputUnion U;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion {
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        // Unicode input avoids the clipboard and handles punctuation, accents, and emoji safely.
        public static void SendUnicodeText(string text) {
            foreach (char ch in text) {
                INPUT down = new INPUT {
                    type = INPUT_KEYBOARD,
                    U = new InputUnion { ki = new KEYBDINPUT { wScan = ch, dwFlags = KEYEVENTF_UNICODE } }
                };
                INPUT up = new INPUT {
                    type = INPUT_KEYBOARD,
                    U = new InputUnion { ki = new KEYBDINPUT { wScan = ch, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } }
                };
                var inputs = new INPUT[] { down, up };
                if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) != inputs.Length) {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SendInput failed while entering the Groupy tab title.");
                }
            }
        }
    }
}
'@
}

# This independent poller is deliberately separate from the event-hook class. It searches the
# native dialog tree continuously right after the hotkey, so it can submit the dialog before
# Groupy has a chance to paint it.
if (-not ('CodexGroupy.DialogPollNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class DialogPollNativeV1 {
        private const uint WM_SETTEXT = 0x000C;
        private const uint BM_CLICK = 0x00F5;
        private const int SW_HIDE = 0;
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, string lParam);
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        private static bool IsReadyRenameDialog(IntPtr hWnd) {
            var className = new StringBuilder(32);
            GetClassName(hWnd, className, className.Capacity);
            return className.ToString() == "#32770" &&
                FindWindowEx(hWnd, IntPtr.Zero, "Edit", null) != IntPtr.Zero &&
                FindWindowEx(hWnd, IntPtr.Zero, "Button", "OK") != IntPtr.Zero;
        }

        public static IntPtr FindReadyRenameDialog(uint expectedProcessId) {
            IntPtr found = IntPtr.Zero;
            EnumWindows((hWnd, _) => {
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner != expectedProcessId || !IsReadyRenameDialog(hWnd)) return true;
                found = hWnd;
                return false;
            }, IntPtr.Zero);
            return found;
        }

        public static bool CommitRename(IntPtr dialog, string title) {
            IntPtr edit = FindWindowEx(dialog, IntPtr.Zero, "Edit", null);
            IntPtr button = FindWindowEx(dialog, IntPtr.Zero, "Button", "OK");
            if (edit == IntPtr.Zero || button == IntPtr.Zero) return false;
            // Works for a dialog that has not yet been shown as well as an already-visible one.
            ShowWindow(dialog, SW_HIDE);
            SendMessage(edit, WM_SETTEXT, IntPtr.Zero, title);
            SendMessage(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            return true;
        }
    }
}
'@
}

# Keep this API separate from Native: classes loaded by Add-Type cannot be redefined in an
# existing integrated PowerShell terminal after the script changes.
if (-not ('CodexGroupy.WindowTitleNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class WindowTitleNative {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetWindowText(IntPtr hWnd, string lpString);
    }
}
'@
}

if (-not ('CodexGroupy.WindowTitleReadNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class WindowTitleReadNativeV1 {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        public static string Read(IntPtr hWnd) {
            var text = new StringBuilder(2048);
            GetWindowText(hWnd, text, text.Capacity);
            return text.ToString();
        }
    }
}
'@
}

if (-not ('CodexGroupy.TitleSyncEventNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace CodexGroupy {
    public static class TitleSyncEventNativeV1 {
        private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        private const uint EVENT_OBJECT_NAMECHANGE = 0x800C;
        private const uint WINEVENT_OUTOFCONTEXT = 0;
        public delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hWnd, int objectId, int childId, uint eventThread, uint eventTime);
        private static readonly WinEventProc Callback = OnEvent;
        private static readonly ConcurrentDictionary<uint, string> ProcessNameById = new ConcurrentDictionary<uint, string>();
        private static long Generation;

        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventProc callback, uint processId, uint threadId, uint flags);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool UnhookWinEvent(IntPtr hook);

        private static bool IsCodeProcess(uint processId) {
            if (processId == 0) return false;
            try {
                string name = ProcessNameById.GetOrAdd(processId, id => Process.GetProcessById((int)id).ProcessName);
                return name.Equals("Code", StringComparison.OrdinalIgnoreCase) || name.Equals("Code - Insiders", StringComparison.OrdinalIgnoreCase);
            } catch { return false; }
        }

        private static bool IsCodeWindow(IntPtr hWnd) {
            uint processId; GetWindowThreadProcessId(hWnd, out processId);
            return IsCodeProcess(processId);
        }

        private static void OnEvent(IntPtr hook, uint eventType, IntPtr hWnd, int objectId, int childId, uint eventThread, uint eventTime) {
            if (eventType == EVENT_SYSTEM_FOREGROUND) {
                if (IsCodeWindow(GetForegroundWindow())) Interlocked.Increment(ref Generation);
                return;
            }
            if (eventType != EVENT_OBJECT_NAMECHANGE) return;
            var foreground = GetForegroundWindow();
            // The poll already detects native caption drift. Ignore our own SetWindowText notification.
            if (hWnd == foreground && objectId == 0 && childId == 0) return;
            if (hWnd != IntPtr.Zero && (hWnd == foreground || GetAncestor(hWnd, 2) == foreground) && IsCodeWindow(foreground))
                Interlocked.Increment(ref Generation);
        }

        public static IntPtr StartForegroundHook() {
            return SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, Callback, 0, 0, WINEVENT_OUTOFCONTEXT);
        }

        public static IntPtr StartFocusNameHook() {
            return SetWinEventHook(EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, Callback, 0, 0, WINEVENT_OUTOFCONTEXT);
        }

        public static long GetGeneration() {
            return Interlocked.Read(ref Generation);
        }
    }
}
'@
}

if (-not ('CodexGroupy.DialogNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class DialogNative {
        private const uint WM_SETTEXT = 0x000C;
        private const uint BM_CLICK = 0x00F5;
        private const int SW_HIDE = 0;

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, string lParam);

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        public static IntPtr FindVisibleRenameDialog(uint groupyProcessId) {
            IntPtr found = IntPtr.Zero;
            EnumWindows((hWnd, _) => {
                if (!IsWindowVisible(hWnd)) return true;
                uint processId;
                GetWindowThreadProcessId(hWnd, out processId);
                if (processId != groupyProcessId) return true;
                var className = new StringBuilder(32);
                GetClassName(hWnd, className, className.Capacity);
                if (className.ToString() != "#32770") return true;
                if (FindWindowEx(hWnd, IntPtr.Zero, "Edit", null) == IntPtr.Zero) return true;
                found = hWnd;
                return false;
            }, IntPtr.Zero);
            return found;
        }

        public static bool CommitRename(IntPtr dialog, string title) {
            IntPtr edit = FindWindowEx(dialog, IntPtr.Zero, "Edit", null);
            if (edit == IntPtr.Zero) return false;

            // Prevent the transient Groupy dialog from remaining on screen while its standard
            // controls are updated. WM_SETTEXT is safely marshalled by Windows across processes.
            ShowWindow(dialog, SW_HIDE);
            SendMessage(edit, WM_SETTEXT, IntPtr.Zero, title);

            IntPtr button = FindWindowEx(dialog, IntPtr.Zero, "Button", "OK");
            if (button == IntPtr.Zero) return false;
            SendMessage(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            return true;
        }
    }
}
'@
}

# V2 uses an event hook registered before the Groupy shortcut is sent. It remains a separate class
# so a PowerShell integrated terminal that loaded a prior script version can use the upgrade at once.
if (-not ('CodexGroupy.DialogNativeV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class DialogNativeV2 {
        private const uint EVENT_OBJECT_SHOW = 0x8002;
        private const int OBJID_WINDOW = 0;
        private const uint WINEVENT_OUTOFCONTEXT = 0;
        private const uint WM_SETTEXT = 0x000C;
        private const uint BM_CLICK = 0x00F5;
        private const int SW_HIDE = 0;

        private delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hWnd, int idObject, int idChild, uint eventThread, uint eventTime);
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        private static readonly object Gate = new object();
        private static WinEventProc callback = OnWinEvent;
        private static IntPtr hook = IntPtr.Zero;
        private static uint processId;
        private static IntPtr detectedDialog = IntPtr.Zero;

        [DllImport("user32.dll")]
        private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventProc callback, uint processId, uint threadId, uint flags);

        [DllImport("user32.dll")]
        private static extern bool UnhookWinEvent(IntPtr hook);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, string lParam);

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        public static void Begin(uint targetProcessId) {
            End();
            lock (Gate) {
                processId = targetProcessId;
                detectedDialog = IntPtr.Zero;
                hook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, callback, targetProcessId, 0, WINEVENT_OUTOFCONTEXT);
            }
        }

        public static void End() {
            lock (Gate) {
                if (hook != IntPtr.Zero) UnhookWinEvent(hook);
                hook = IntPtr.Zero;
                processId = 0;
                detectedDialog = IntPtr.Zero;
            }
        }

        public static IntPtr DetectedDialog() {
            lock (Gate) return detectedDialog;
        }

        private static bool IsRenameDialog(IntPtr hWnd) {
            var className = new StringBuilder(32);
            GetClassName(hWnd, className, className.Capacity);
            return className.ToString() == "#32770" && FindWindowEx(hWnd, IntPtr.Zero, "Edit", null) != IntPtr.Zero;
        }

        private static void OnWinEvent(IntPtr ignored, uint eventType, IntPtr hWnd, int idObject, int idChild, uint eventThread, uint eventTime) {
            if (eventType != EVENT_OBJECT_SHOW || idObject != OBJID_WINDOW || hWnd == IntPtr.Zero) return;
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);
            lock (Gate) {
                if (owner != processId || !IsRenameDialog(hWnd)) return;
                // Hides before the next normal paint; direct control messages still work when hidden.
                ShowWindow(hWnd, SW_HIDE);
                detectedDialog = hWnd;
            }
        }

        public static IntPtr FindVisibleRenameDialog(uint expectedProcessId) {
            IntPtr found = IntPtr.Zero;
            EnumWindows((hWnd, _) => {
                if (!IsWindowVisible(hWnd)) return true;
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner != expectedProcessId || !IsRenameDialog(hWnd)) return true;
                found = hWnd;
                return false;
            }, IntPtr.Zero);
            return found;
        }

        public static bool CommitRename(IntPtr dialog, string title) {
            IntPtr edit = FindWindowEx(dialog, IntPtr.Zero, "Edit", null);
            if (edit == IntPtr.Zero) return false;
            SendMessage(edit, WM_SETTEXT, IntPtr.Zero, title);
            IntPtr button = FindWindowEx(dialog, IntPtr.Zero, "Button", "OK");
            if (button == IntPtr.Zero) return false;
            SendMessage(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            return true;
        }
    }
}

'@
}

if ($UseInProcessNoFlashHook -and -not ('CodexGroupy.InProcessHookNativeV2' -as [type])) {
    $hookDllPath = Join-Path $PSScriptRoot 'GroupyNoFlashHookV2.dll'
    if (-not (Test-Path -LiteralPath $hookDllPath)) {
        throw "Missing experimental helper: $hookDllPath"
    }
    $hookDllForCSharp = $hookDllPath.Replace('\', '\\')
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class InProcessHookNativeV2 {
        [DllImport("$hookDllForCSharp", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool InstallNoFlashHook(uint threadId);

        [DllImport("$hookDllForCSharp", SetLastError = true)]
        public static extern void RemoveNoFlashHooks();

        [DllImport("$hookDllForCSharp", SetLastError = true)]
        public static extern uint GetNoFlashHookLastError();
    }
}
"@
}

# V3 also listens for creation. EVENT_OBJECT_SHOW is too late to promise that no pixels reach
# the screen: by definition, the dialog is already visible when that event arrives. Hiding the
# Groupy dialog at creation keeps it non-visible while its child controls are added; SHOW remains
# a belt-and-suspenders backstop because Groupy can explicitly show it after creation.
if (-not ('CodexGroupy.DialogNativeV3' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class DialogNativeV3 {
        private const uint EVENT_OBJECT_CREATE = 0x8000;
        private const uint EVENT_OBJECT_SHOW = 0x8002;
        private const int OBJID_WINDOW = 0;
        private const uint WINEVENT_OUTOFCONTEXT = 0;
        private const uint WM_SETTEXT = 0x000C;
        private const uint BM_CLICK = 0x00F5;
        private const int SW_HIDE = 0;

        private delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hWnd, int idObject, int idChild, uint eventThread, uint eventTime);
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        private static readonly object Gate = new object();
        private static WinEventProc callback = OnWinEvent;
        private static IntPtr hook = IntPtr.Zero;
        private static uint processId;
        private static IntPtr detectedDialog = IntPtr.Zero;

        [DllImport("user32.dll")]
        private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventProc callback, uint processId, uint threadId, uint flags);
        [DllImport("user32.dll")]
        private static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, string lParam);
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        public static void Begin(uint targetProcessId) {
            End();
            lock (Gate) {
                processId = targetProcessId;
                detectedDialog = IntPtr.Zero;
                hook = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW, IntPtr.Zero, callback, targetProcessId, 0, WINEVENT_OUTOFCONTEXT);
            }
        }

        public static void End() {
            lock (Gate) {
                if (hook != IntPtr.Zero) UnhookWinEvent(hook);
                hook = IntPtr.Zero;
                processId = 0;
                detectedDialog = IntPtr.Zero;
            }
        }

        public static IntPtr DetectedDialog() { lock (Gate) return detectedDialog; }

        private static bool IsGroupyDialog(IntPtr hWnd) {
            var className = new StringBuilder(32);
            GetClassName(hWnd, className, className.Capacity);
            return className.ToString() == "#32770";
        }

        private static bool IsRenameDialog(IntPtr hWnd) {
            return IsGroupyDialog(hWnd) && FindWindowEx(hWnd, IntPtr.Zero, "Edit", null) != IntPtr.Zero;
        }

        private static void OnWinEvent(IntPtr ignored, uint eventType, IntPtr hWnd, int idObject, int idChild, uint eventThread, uint eventTime) {
            if (idObject != OBJID_WINDOW || hWnd == IntPtr.Zero) return;
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);
            lock (Gate) {
                if (owner != processId || !IsGroupyDialog(hWnd)) return;
                // CREATE happens before Groupy has populated or painted this #32770 dialog.
                ShowWindow(hWnd, SW_HIDE);
                if (IsRenameDialog(hWnd)) detectedDialog = hWnd;
            }
        }

        public static IntPtr FindVisibleRenameDialog(uint expectedProcessId) {
            IntPtr found = IntPtr.Zero;
            EnumWindows((hWnd, _) => {
                if (!IsWindowVisible(hWnd)) return true;
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner != expectedProcessId || !IsRenameDialog(hWnd)) return true;
                found = hWnd;
                return false;
            }, IntPtr.Zero);
            return found;
        }

        public static bool CommitRename(IntPtr dialog, string title) {
            IntPtr edit = FindWindowEx(dialog, IntPtr.Zero, "Edit", null);
            if (edit == IntPtr.Zero) return false;
            SendMessage(edit, WM_SETTEXT, IntPtr.Zero, title);
            IntPtr button = FindWindowEx(dialog, IntPtr.Zero, "Button", "OK");
            if (button == IntPtr.Zero) return false;
            SendMessage(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            return true;
        }
    }
}
'@
}

# V4 makes the short-lived dialog fully transparent at creation in addition to hiding it. This
# matters because Groupy may call ShowWindow itself after the CREATE notification; alpha remains
# zero through that call, so there is no dialog frame to paint before native controls submit it.
if (-not ('CodexGroupy.DialogNativeV4' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public static class DialogNativeV4 {
        private const uint EVENT_OBJECT_CREATE = 0x8000;
        private const uint EVENT_OBJECT_SHOW = 0x8002;
        private const int OBJID_WINDOW = 0;
        private const uint WINEVENT_OUTOFCONTEXT = 0;
        private const uint WM_SETTEXT = 0x000C;
        private const uint BM_CLICK = 0x00F5;
        private const int SW_HIDE = 0;
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_LAYERED = 0x00080000L;
        private const uint LWA_ALPHA = 0x00000002;

        private delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hWnd, int idObject, int idChild, uint eventThread, uint eventTime);
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        private static readonly object Gate = new object();
        private static WinEventProc callback = OnWinEvent;
        private static IntPtr hook = IntPtr.Zero;
        private static uint processId;
        private static IntPtr detectedDialog = IntPtr.Zero;

        [DllImport("user32.dll")]
        private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventProc callback, uint processId, uint threadId, uint flags);
        [DllImport("user32.dll")]
        private static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, string lParam);
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
        private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);
        [DllImport("user32.dll")]
        private static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint colorKey, byte alpha, uint flags);

        public static void Begin(uint targetProcessId) {
            End();
            lock (Gate) {
                processId = targetProcessId;
                detectedDialog = IntPtr.Zero;
                hook = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW, IntPtr.Zero, callback, targetProcessId, 0, WINEVENT_OUTOFCONTEXT);
            }
        }

        public static void End() {
            lock (Gate) {
                if (hook != IntPtr.Zero) UnhookWinEvent(hook);
                hook = IntPtr.Zero;
                processId = 0;
                detectedDialog = IntPtr.Zero;
            }
        }

        public static IntPtr DetectedDialog() { lock (Gate) return detectedDialog; }

        private static bool IsGroupyDialog(IntPtr hWnd) {
            var className = new StringBuilder(32);
            GetClassName(hWnd, className, className.Capacity);
            return className.ToString() == "#32770";
        }

        private static bool IsRenameDialog(IntPtr hWnd) {
            return IsGroupyDialog(hWnd) && FindWindowEx(hWnd, IntPtr.Zero, "Edit", null) != IntPtr.Zero;
        }

        private static void MakeInvisible(IntPtr hWnd) {
            long style = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
            SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(style | WS_EX_LAYERED));
            SetLayeredWindowAttributes(hWnd, 0, 0, LWA_ALPHA);
            ShowWindow(hWnd, SW_HIDE);
        }

        private static void OnWinEvent(IntPtr ignored, uint eventType, IntPtr hWnd, int idObject, int idChild, uint eventThread, uint eventTime) {
            if (idObject != OBJID_WINDOW || hWnd == IntPtr.Zero) return;
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);
            lock (Gate) {
                if (owner != processId || !IsGroupyDialog(hWnd)) return;
                MakeInvisible(hWnd);
                if (IsRenameDialog(hWnd)) detectedDialog = hWnd;
            }
        }

        public static IntPtr FindVisibleRenameDialog(uint expectedProcessId) {
            IntPtr found = IntPtr.Zero;
            EnumWindows((hWnd, _) => {
                if (!IsWindowVisible(hWnd)) return true;
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner != expectedProcessId || !IsRenameDialog(hWnd)) return true;
                found = hWnd;
                return false;
            }, IntPtr.Zero);
            return found;
        }

        public static bool CommitRename(IntPtr dialog, string title) {
            IntPtr edit = FindWindowEx(dialog, IntPtr.Zero, "Edit", null);
            if (edit == IntPtr.Zero) return false;
            SendMessage(edit, WM_SETTEXT, IntPtr.Zero, title);
            IntPtr button = FindWindowEx(dialog, IntPtr.Zero, "Button", "OK");
            if (button == IntPtr.Zero) return false;
            SendMessage(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            return true;
        }
    }
}
'@
}

function Get-ForegroundCodeWindow {
    param([switch]$IncludeRoot)
    $hwnd = [CodexGroupy.Native]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }

    [uint32]$processId = 0
    [void][CodexGroupy.Native]::GetWindowThreadProcessId($hwnd, [ref]$processId)
    if ($processId -eq 0) { return $null }

    try { $process = Get-Process -Id $processId -ErrorAction Stop } catch { return $null }
    if ($process.ProcessName -notin @('Code', 'Code - Insiders')) { return $null }

    $result = [ordered]@{
        Handle = $hwnd
        Process = $process
    }
    if ($IncludeRoot) {
        $result.Root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    }
    [pscustomobject]$result
}

function Get-ForegroundCodeWindowHandle {
    $hwnd = [CodexGroupy.Native]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    if (-not [CodexGroupy.Native]::IsCodeWindow($hwnd)) { return [IntPtr]::Zero }
    return $hwnd
}

function Get-OpenCodeWindows {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('Code', 'Code - Insiders') -and $_.MainWindowHandle -ne 0
    } | ForEach-Object {
        [pscustomobject]@{
            Handle = [IntPtr]$_.MainWindowHandle
            Process = $_
            Root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$_.MainWindowHandle)
        }
    }
}

. (Join-Path $PSScriptRoot 'CodexGroupyTitleProbe.ps1')

function Get-WorkspaceNameFromNativeTitle([string]$Title) {
    # Before this helper changes a caption, VS Code uses "file - workspace - Visual Studio Code".
    # The final segment is stable even when the active editor file changes, so it is a useful
    # fallback when VS Code's Files Explorer accessibility tree is temporarily unavailable.
    $clean = ConvertTo-GroupyTitle $Title
    if ($clean -notmatch '\s+-\s+Visual Studio Code(?: - Insiders)?$') { return $null }
    $clean = $clean -replace '\s+-\s+Visual Studio Code(?: - Insiders)?$', ''
    $parts = @($clean -split '\s+-\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -ge 2) { return ConvertTo-GroupyTitle $parts[$parts.Count - 1] }
    return $null
}

function Get-WorkspaceLabel([System.Windows.Automation.AutomationElement]$Root) {
    $name = $Root.Current.Name
    return ($name -replace '\s+-\s+Visual Studio Code$', '')
}

function Invoke-GroupyRename([string]$Title) {
    $title = ConvertTo-GroupyTitle $Title
    if (-not $title) { return }

    # This is intentionally sent only while the target VS Code window is foreground.
    $groupy = Get-Process GroupyCtrl -ErrorAction Stop | Select-Object -First 1
    $inProcessHookInstalled = $false
    if ($UseInProcessNoFlashHook) {
        [CodexGroupy.InProcessHookNativeV2]::RemoveNoFlashHooks()
        # Groupy can host its UI in GroupyCtrl or in its injected component within the active
        # application. Hook both process thread sets for this short, one-rename interval.
        $hookProcesses = @($groupy)
        $activeCode = Get-ForegroundCodeWindow
        if ($activeCode -and $activeCode.Process.Id -ne $groupy.Id) {
            $hookProcesses += $activeCode.Process
        }
        $hookThreadIds = @($hookProcesses | ForEach-Object { $_.Threads | ForEach-Object { $_.Id } } | Sort-Object -Unique)
        foreach ($threadId in $hookThreadIds) {
            if ([CodexGroupy.InProcessHookNativeV2]::InstallNoFlashHook([uint32]$threadId)) {
                $inProcessHookInstalled = $true
            }
        }
        if (-not $inProcessHookInstalled) {
            $errorCode = [CodexGroupy.InProcessHookNativeV2]::GetNoFlashHookLastError()
            throw "Could not install the experimental in-process Groupy hook (Win32 error $errorCode)."
        }
    }
    [CodexGroupy.DialogNativeV4]::Begin([uint32]$groupy.Id)
    try {
        [System.Windows.Forms.SendKeys]::SendWait($RenameHotkey)
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $dialog = [IntPtr]::Zero
        $renamed = $false
        while ($deadline.ElapsedMilliseconds -lt $RenameDialogDelayMs) {
            $dialog = [CodexGroupy.DialogNativeV4]::DetectedDialog()
            if ($dialog -eq [IntPtr]::Zero) {
                # Avoid waiting on an out-of-process accessibility event. The dialog can exist,
                # have its controls, and still not have been painted yet.
                $dialog = [CodexGroupy.DialogPollNativeV1]::FindReadyRenameDialog([uint32]$groupy.Id)
            }
            if ($dialog -ne [IntPtr]::Zero -and [CodexGroupy.DialogPollNativeV1]::CommitRename($dialog, $title)) {
                $renamed = $true
                break
            }
            [Threading.Thread]::SpinWait(128)
        }
        if (-not $renamed) {
            # Fallback for an event delivery delay; it is retained only for cold-start resilience.
            $dialog = [CodexGroupy.DialogNativeV4]::FindVisibleRenameDialog([uint32]$groupy.Id)
        }
        if ($dialog -ne [IntPtr]::Zero -and $VerbosePreference -eq 'Continue') {
            [uint32]$dialogProcessId = 0
            $dialogThreadId = [CodexGroupy.Native]::GetWindowThreadProcessId($dialog, [ref]$dialogProcessId)
            Write-Verbose ("Groupy rename dialog: hwnd=0x{0:X}, pid={1}, thread={2}" -f $dialog.ToInt64(), $dialogProcessId, $dialogThreadId)
        }
        if (-not $renamed -and ($dialog -eq [IntPtr]::Zero -or -not [CodexGroupy.DialogNativeV4]::CommitRename($dialog, $title))) {
            throw 'Groupy Rename Tab dialog did not become available.'
        }
    } finally {
        [CodexGroupy.DialogNativeV4]::End()
        if ($UseInProcessNoFlashHook -and $inProcessHookInstalled) {
            [CodexGroupy.InProcessHookNativeV2]::RemoveNoFlashHooks()
        }
    }
}

function Set-NativeWindowTitle([IntPtr]$Handle, [string]$Title) {
    $title = ConvertTo-GroupyTitle $Title
    if (-not $title) { return }
    if (-not [CodexGroupy.WindowTitleNative]::SetWindowText($Handle, $title)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'SetWindowText failed.')
    }
}

function Get-NativeWindowTitle([IntPtr]$Handle) {
    return [CodexGroupy.WindowTitleReadNativeV1]::Read($Handle)
}

function Write-DebugSnapshot($window) {
    $title = Get-CodexActiveTitle $window.Root
    [pscustomobject]@{
        ActiveHwnd = ('0x{0:X}' -f $window.Handle.ToInt64())
        Process = "$($window.Process.ProcessName).exe ($($window.Process.Id))"
        Workspace = Get-WorkspaceLabel $window.Root
        CodexConversationTitle = if ($title) { $title } else { '<none detected: open an existing Codex chat, not the home/new-chat screen>' }
    } | Format-List
}

$renameHotkeyEnabled = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Stardock\Groupy\Groupy.ini\Groupy' -ErrorAction SilentlyContinue).AlsoRegisterRenameKey
if ($renameHotkeyEnabled -ne 1 -and ($TestRename -or $Watch)) {
    Write-Warning 'Groupy Rename Tab hotkey is not enabled. Configure it in Groupy 2 before using -TestRename or -Watch.'
}

if ($TestRename) {
    if ($StartDelaySeconds -gt 0) {
        Write-Host "Switch to the target grouped VS Code tab within $StartDelaySeconds seconds..."
        Start-Sleep -Seconds $StartDelaySeconds
    }
    $window = Get-ForegroundCodeWindow -IncludeRoot
    if (-not $window) { throw 'Activate a grouped VS Code window, then run -TestRename.' }
    Invoke-GroupyRename $TestTitle
    Write-Host "Sent Groupy rename request: $TestTitle"
    return
}

if ($TestNativeTitle) {
    if ($StartDelaySeconds -gt 0) {
        Write-Host "Switch to the target grouped VS Code tab within $StartDelaySeconds seconds..."
        Start-Sleep -Seconds $StartDelaySeconds
    }
    $window = Get-ForegroundCodeWindow
    if (-not $window) { throw 'Activate a grouped VS Code window, then run -TestNativeTitle.' }
    Set-NativeWindowTitle $window.Handle $TestTitle
    Write-Host "Set the native VS Code window title to: $TestTitle"
    Write-Host 'Check whether Groupy changed the current tab without displaying its Rename Tab dialog.'
    return
}

if ($Inspect -or (-not $Watch -and -not $WatchAutoTitle)) {
    $window = Get-ForegroundCodeWindow -IncludeRoot
    if ($window) {
        Write-DebugSnapshot $window
    } else {
        $windows = @(Get-OpenCodeWindows)
        if ($windows.Count -eq 0) {
            Write-Host 'No open VS Code windows found.'
        } else {
            Write-Host 'Foreground window is not VS Code; inspecting each open VS Code window instead.'
            $windows | ForEach-Object { Write-DebugSnapshot $_ }
        }
    }
    if (-not $Watch -and -not $WatchAutoTitle) { return }
}

$lastTitleByHwnd = @{}
$lastUiAutomationWarningAt = [DateTime]::MinValue
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$titleSyncDiagnosticsPath = Join-Path $repoRoot 'work\CodexGroupyTabSyncRuntime.log'
function Write-TitleSyncDiagnostic([string]$Message) {
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
        [System.IO.File]::AppendAllText($titleSyncDiagnosticsPath, $line + [Environment]::NewLine)
    } catch {}
}
$script:titleProbeWorker = $null

function Stop-TitleProbeWorker {
    if ($null -eq $script:titleProbeWorker) { return }
    $worker = $script:titleProbeWorker
    if (-not $worker.HasExited) {
        try { $worker.Kill() } catch { if (-not $worker.HasExited) { throw } }
    }
    $worker.Dispose()
    $script:titleProbeWorker = $null
}

function Invoke-TitleProbe([IntPtr]$Handle, [bool]$NeedWorkspace) {
    if ($null -eq $script:titleProbeWorker -or $script:titleProbeWorker.HasExited) {
        Stop-TitleProbeWorker
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $workerPath = Join-Path $PSScriptRoot 'CodexGroupyTitleProbe.ps1'
        $startInfo.Arguments = '-NoProfile -NonInteractive -MTA -ExecutionPolicy Bypass -File "{0}" -ParentProcessId {1}' -f $workerPath, $PID
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $script:titleProbeWorker = [Diagnostics.Process]::Start($startInfo)
    }

    $request = @{ Handle = $Handle.ToInt64(); NeedWorkspace = $NeedWorkspace } | ConvertTo-Json -Compress
    $script:titleProbeWorker.StandardInput.WriteLine($request)
    $reply = $script:titleProbeWorker.StandardOutput.ReadLineAsync()
    if (-not $reply.Wait(3000)) {
        throw [TimeoutException]::new('Accessibility scan exceeded 3 seconds.')
    }
    if ([string]::IsNullOrWhiteSpace($reply.Result)) { throw 'Title probe worker exited without a reply.' }
    $result = ConvertFrom-Json -InputObject $reply.Result
    if ($result.Error) { throw "Title probe failed: $($result.Error)." }
    return $result
}

function Watch-AutoTitle {
    $foregroundHook = [CodexGroupy.TitleSyncEventNativeV1]::StartForegroundHook()
    $nameHook = [CodexGroupy.TitleSyncEventNativeV1]::StartFocusNameHook()
    $windows = @{}
    $retrySeconds = 0
    $nextProbeAt = [DateTime]::MinValue
    $pendingKey = $null
    $pendingSince = [DateTime]::MinValue
    Write-Host 'Watching the foreground VS Code window in no-dialog auto-title mode. Press Ctrl+C to stop.'
    try {
        while ($true) {
            Start-Sleep -Milliseconds $PollIntervalMs
            # Out-of-context WinEvent hooks deliver callbacks on the registering thread.
            [System.Windows.Forms.Application]::DoEvents()
            $now = [DateTime]::UtcNow
            $handle = Get-ForegroundCodeWindowHandle
            if ($handle -eq [IntPtr]::Zero -or [CodexGroupy.Native]::IsHungAppWindow($handle)) {
                $pendingKey = $null
                continue
            }
            [uint32]$processId = 0
            [void][CodexGroupy.Native]::GetWindowThreadProcessId($handle, [ref]$processId)
            $key = '{0}:0x{1:X}' -f $processId, $handle.ToInt64()
            $generation = [CodexGroupy.TitleSyncEventNativeV1]::GetGeneration()
            $cached = $windows[$key]
            $nativeTitle = Get-NativeWindowTitle $handle
            $reason = if (-not $cached) { 'cold' }
                elseif ($nativeTitle -ne $cached.DesiredTitle) { 'native-title-drift' }
                elseif ($now -ge $cached.RefreshAt) { 'safety' }
                elseif ($generation -ne $cached.Generation) { 'win-event' }
                else { $null }
            if (-not $reason) { $pendingKey = $null; continue }
            if ($pendingKey -ne $key) {
                $pendingKey = $key
                $pendingSince = $now
            }
            # Coalesce a burst on one window without waiting forever for quiet.
            if ($now -lt $nextProbeAt -or ($now - $pendingSince).TotalMilliseconds -lt 250) { continue }
            $pendingKey = $null

            $workspace = Get-WorkspaceNameFromNativeTitle $nativeTitle
            if (-not $workspace -and $cached) { $workspace = $cached.Workspace }
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $target = Invoke-TitleProbe -Handle $handle -NeedWorkspace (-not $workspace)
            } catch {
                Stop-TitleProbeWorker
                $retrySeconds = if ($retrySeconds -eq 0) { 5 } else { [math]::Min(60, 2 * $retrySeconds) }
                $nextProbeAt = [DateTime]::UtcNow.AddSeconds($retrySeconds)
                Write-TitleSyncDiagnostic "uia-probe $key reason=$reason elapsedMs=$($stopwatch.ElapsedMilliseconds) retrySeconds=$retrySeconds error=$($_.Exception.Message)"
                continue
            }
            $stopwatch.Stop()
            $finishedAt = [DateTime]::UtcNow
            $retrySeconds = 0
            $nextProbeAt = $finishedAt.AddMilliseconds(500)
            if ($stopwatch.ElapsedMilliseconds -ge 75) {
                Write-TitleSyncDiagnostic "uia-probe hwnd=0x$($handle.ToInt64().ToString('X')) reason=$reason elapsedMs=$($stopwatch.ElapsedMilliseconds)"
            }

            # A completed scan belongs to its original foreground window.
            [uint32]$currentProcessId = 0
            [void][CodexGroupy.Native]::GetWindowThreadProcessId($handle, [ref]$currentProcessId)
            if ($handle -ne (Get-ForegroundCodeWindowHandle) -or $processId -ne $currentProcessId -or
                [CodexGroupy.Native]::IsHungAppWindow($handle)) { continue }

            $nativeTitle = Get-NativeWindowTitle $handle
            $currentWorkspace = Get-WorkspaceNameFromNativeTitle $nativeTitle
            if ($currentWorkspace) { $workspace = $currentWorkspace }
            elseif ($target.Workspace) { $workspace = $target.Workspace }
            $desiredTitle = if ($target.State -eq 'chat') { $target.Title }
                elseif ($workspace) { $workspace }
                elseif ($target.State -eq 'home') { ConvertTo-GroupyTitle $CodexHomeTitle }
                else { ConvertTo-GroupyTitle $CodexClosedTitle }
            if ($desiredTitle -and $nativeTitle -ne $desiredTitle) {
                try {
                    Set-NativeWindowTitle $handle $desiredTitle
                    $latencyMs = [long]([DateTime]::UtcNow - $pendingSince).TotalMilliseconds
                    Write-TitleSyncDiagnostic "title-update reason=$reason latencyMs=$latencyMs scanMs=$($stopwatch.ElapsedMilliseconds)"
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $key -> $desiredTitle ($($target.State))"
                } catch {
                    Write-TitleSyncDiagnostic "caption-update $key error=$($_.Exception.Message)"
                    $nextProbeAt = [DateTime]::UtcNow.AddSeconds(5)
                    continue
                }
            }
            $windows[$key] = [pscustomobject]@{
                DesiredTitle = if ($desiredTitle) { $desiredTitle } else { $nativeTitle }
                Workspace = $workspace
                RefreshAt = $finishedAt.AddSeconds(8)
                Generation = $generation
            }
        }
    } finally {
        Stop-TitleProbeWorker
        if ($foregroundHook -ne [IntPtr]::Zero) { [void][CodexGroupy.TitleSyncEventNativeV1]::UnhookWinEvent($foregroundHook) }
        if ($nameHook -ne [IntPtr]::Zero) { [void][CodexGroupy.TitleSyncEventNativeV1]::UnhookWinEvent($nameHook) }
    }
}

if ($WatchAutoTitle) {
    Watch-AutoTitle
    return
}

Write-Host 'Watching the foreground VS Code window. Press Ctrl+C to stop.'
while ($true) {
    try {
        $window = Get-ForegroundCodeWindow -IncludeRoot
        if ($window) {
            $title = Get-CodexActiveTitle $window.Root
            if ($title) {
                $key = $window.Handle.ToInt64().ToString('X')
                if ($lastTitleByHwnd[$key] -ne $title) {
                    Invoke-GroupyRename $title
                    $lastTitleByHwnd[$key] = $title
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $key -> $title"
                }
            }
        }
    } catch {
        # UI Automation can briefly lose VS Code's process token while Electron rebuilds its
        # accessibility tree. Retrying on the next poll is the correct recovery; other failures
        # remain visible instead of being silently hidden.
        $inner = $_.Exception.InnerException
        $isTransientUiaFailure = $_.Exception -is [Runtime.InteropServices.COMException] -or $inner -is [Runtime.InteropServices.COMException]
        if (-not $isTransientUiaFailure) { throw }
        if (((Get-Date) - $lastUiAutomationWarningAt).TotalSeconds -ge 5) {
            Write-Host 'VS Code accessibility tree changed; retrying automatically.' -ForegroundColor DarkYellow
            $lastUiAutomationWarningAt = Get-Date
        }
    }
    Start-Sleep -Milliseconds $PollIntervalMs
}
