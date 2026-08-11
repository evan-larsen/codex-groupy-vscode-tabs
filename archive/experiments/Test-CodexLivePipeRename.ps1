[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ThreadId,

    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$Request
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Experimental, current-version-only path. It duplicates the live Codex app-server's
# stdin handle and writes one JSON-RPC message. By default it is a notification;
# -Request uses the request shape required by methods that do not accept notifications.
if (-not ('CodexGroupy.LivePipeRenameV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexGroupy {
    public static class LivePipeRenameV1 {
        private const uint PROCESS_DUP_HANDLE = 0x0040;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;
        private const uint DUPLICATE_SAME_ACCESS = 0x00000002;

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_BASIC_INFORMATION {
            public IntPtr Reserved1;
            public IntPtr PebBaseAddress;
            public IntPtr Reserved2_0;
            public IntPtr Reserved2_1;
            public IntPtr UniqueProcessId;
            public IntPtr Reserved3;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr processHandle, int processInformationClass, IntPtr processInformation, int processInformationLength, out int returnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadProcessMemory(IntPtr process, IntPtr baseAddress, IntPtr buffer, IntPtr size, out IntPtr bytesRead);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DuplicateHandle(IntPtr sourceProcessHandle, IntPtr sourceHandle, IntPtr targetProcessHandle, out IntPtr targetHandle, uint desiredAccess, bool inheritHandle, uint options);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WriteFile(IntPtr handle, byte[] buffer, uint count, out uint written, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        private static IntPtr ReadTargetPointer(IntPtr process, IntPtr address) {
            IntPtr buffer = Marshal.AllocHGlobal(IntPtr.Size);
            try {
                IntPtr read;
                if (!ReadProcessMemory(process, address, buffer, (IntPtr)IntPtr.Size, out read) || read.ToInt64() != IntPtr.Size) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadProcessMemory failed.");
                }
                return Marshal.ReadIntPtr(buffer);
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        public static int SendNotification(int processId, string jsonLine) {
            if (IntPtr.Size != 8) throw new NotSupportedException("This experiment currently expects a 64-bit Codex process.");
            IntPtr process = OpenProcess(PROCESS_DUP_HANDLE | PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the live Codex app-server process.");
            IntPtr duplicate = IntPtr.Zero;
            try {
                int size = Marshal.SizeOf<PROCESS_BASIC_INFORMATION>();
                IntPtr basicBuffer = Marshal.AllocHGlobal(size);
                try {
                    int returned;
                    int status = NtQueryInformationProcess(process, 0, basicBuffer, size, out returned);
                    if (status != 0) throw new Win32Exception(status, "NtQueryInformationProcess(ProcessBasicInformation) failed.");
                    var basic = Marshal.PtrToStructure<PROCESS_BASIC_INFORMATION>(basicBuffer);
                    IntPtr parameters = ReadTargetPointer(process, IntPtr.Add(basic.PebBaseAddress, 0x20));
                    IntPtr standardInput = ReadTargetPointer(process, IntPtr.Add(parameters, 0x20));
                    if (!DuplicateHandle(process, standardInput, GetCurrentProcess(), out duplicate, 0, false, DUPLICATE_SAME_ACCESS)) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not duplicate the live Codex stdin handle.");
                    }
                    byte[] payload = Encoding.UTF8.GetBytes(jsonLine + "\n");
                    uint written;
                    if (!WriteFile(duplicate, payload, (uint)payload.Length, out written, IntPtr.Zero)) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteFile to the live Codex stdin handle failed.");
                    }
                    if (written != payload.Length) throw new InvalidOperationException("The live Codex pipe accepted only " + written + " of " + payload.Length + " bytes.");
                    return (int)written;
                } finally { Marshal.FreeHGlobal(basicBuffer); }
            } finally {
                if (duplicate != IntPtr.Zero) CloseHandle(duplicate);
                CloseHandle(process);
            }
        }
    }
}
'@
}

$owner = & (Join-Path $PSScriptRoot 'Inspect-CodexAppServerPipes.ps1') -ThreadId $ThreadId | Out-String
if ($owner -notmatch 'Codex app-server') { throw 'Could not confirm a live Codex app-server owns this thread.' }

$ownerProcess = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -ieq 'codex.exe' -and $_.CommandLine -match '\bapp-server\b'
} | Where-Object {
    $candidate = $_.ProcessId
    $lockPath = Join-Path $env:USERPROFILE ('.codex\thread-writer-locks\{0}.lock' -f $ThreadId)
    # The inspector printed the owner already; select the desktop app-server for the live desktop task.
    $_.ParentProcessId -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)" -ErrorAction SilentlyContinue).Name -eq 'ChatGPT.exe'
} | Select-Object -First 1
if (-not $ownerProcess) { throw 'Could not identify the desktop-owned live Codex app-server.' }

$messageObject = @{ method = 'thread/name/set'; params = @{ threadId = $ThreadId; name = $Name } }
if ($Request) { $messageObject.id = 925000001 }
$message = $messageObject | ConvertTo-Json -Compress -Depth 6
$written = [CodexGroupy.LivePipeRenameV1]::SendNotification([int]$ownerProcess.ProcessId, $message)
"Sent $written bytes as an in-band notification to live Codex app-server PID $($ownerProcess.ProcessId)."
