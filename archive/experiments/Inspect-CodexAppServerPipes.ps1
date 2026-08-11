[CmdletBinding()]
param(
    [string]$ThreadId = '019febf1-11ba-7ba0-8228-cd3e2a220648',

    [switch]$MapPipes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read-only diagnostic helper. It duplicates eligible handles into this helper only
# long enough to identify them; it never writes to a pipe or changes another process.
if (-not ('CodexGroupy.CodexPipeInspectorV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexGroupy {
    public sealed class HandleRecord {
        public int ProcessId { get; set; }
        public string Role { get; set; }
        public string Handle { get; set; }
        public string Kind { get; set; }
        public string Name { get; set; }
        public string Access { get; set; }
    }

    public sealed class StandardHandleSet {
        public int ProcessId { get; set; }
        public string StandardInput { get; set; }
        public string StandardOutput { get; set; }
        public string StandardError { get; set; }
    }

    public static class CodexPipeInspectorV1 {
        private const int SystemExtendedHandleInformation = 64;
        private const int ObjectNameInformation = 1;
        private const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
        private const uint PROCESS_DUP_HANDLE = 0x0040;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;
        private const int ProcessHandleInformation = 51;
        private const uint DUPLICATE_SAME_ACCESS = 0x00000002;
        private const uint FILE_TYPE_DISK = 0x0001;
        private const uint FILE_TYPE_PIPE = 0x0003;

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEM_HANDLE_INFORMATION_EX {
            public IntPtr NumberOfHandles;
            public IntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX {
            public IntPtr Object;
            public IntPtr UniqueProcessId;
            public IntPtr HandleValue;
            public uint GrantedAccess;
            public ushort CreatorBackTraceIndex;
            public ushort ObjectTypeIndex;
            public uint HandleAttributes;
            public uint Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct UNICODE_STRING {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_HANDLE_TABLE_ENTRY_INFO {
            public IntPtr HandleValue;
            public IntPtr HandleCount;
            public IntPtr PointerCount;
            public uint GrantedAccess;
            public uint ObjectTypeIndex;
            public uint HandleAttributes;
            public uint Reserved;
        }

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
        private static extern int NtQuerySystemInformation(int systemInformationClass, IntPtr systemInformation, int systemInformationLength, out int returnLength);
        [DllImport("ntdll.dll")]
        private static extern int NtQueryObject(IntPtr handle, int objectInformationClass, IntPtr objectInformation, int objectInformationLength, out int returnLength);
        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr processHandle, int processInformationClass, IntPtr processInformation, int processInformationLength, out int returnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadProcessMemory(IntPtr process, IntPtr baseAddress, IntPtr buffer, IntPtr size, out IntPtr bytesRead);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DuplicateHandle(IntPtr sourceProcessHandle, IntPtr sourceHandle, IntPtr targetProcessHandle, out IntPtr targetHandle, uint desiredAccess, bool inheritHandle, uint options);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")]
        private static extern uint GetFileType(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint clientProcessId);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint serverProcessId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(IntPtr handle, System.Text.StringBuilder path, uint length, uint flags);

        private static string QueryObjectName(IntPtr handle) {
            int length = 1024;
            for (int attempt = 0; attempt < 5; attempt++) {
                IntPtr buffer = Marshal.AllocHGlobal(length);
                try {
                    int needed;
                    int status = NtQueryObject(handle, ObjectNameInformation, buffer, length, out needed);
                    if (status == 0) {
                        var value = Marshal.PtrToStructure<UNICODE_STRING>(buffer);
                        return value.Buffer == IntPtr.Zero || value.Length == 0 ? "" : Marshal.PtrToStringUni(value.Buffer, value.Length / 2);
                    }
                    if (status != STATUS_INFO_LENGTH_MISMATCH || needed <= length) return "";
                    length = needed + 256;
                } finally { Marshal.FreeHGlobal(buffer); }
            }
            return "";
        }

        private static string QueryFinalPath(IntPtr handle) {
            var path = new System.Text.StringBuilder(2048);
            uint result = GetFinalPathNameByHandle(handle, path, (uint)path.Capacity, 0);
            return result == 0 || result >= path.Capacity ? "" : path.ToString();
        }

        private static string QueryPipePeers(IntPtr handle) {
            uint client = 0, server = 0;
            bool hasClient = GetNamedPipeClientProcessId(handle, out client);
            bool hasServer = GetNamedPipeServerProcessId(handle, out server);
            if (!hasClient && !hasServer) return "anonymous pipe (peer PID unavailable)";
            return String.Format("server={0}; client={1}", hasServer ? server.ToString() : "?", hasClient ? client.ToString() : "?");
        }

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

        public static StandardHandleSet GetStandardHandles(int processId) {
            if (IntPtr.Size != 8) throw new NotSupportedException("This inspector currently expects a 64-bit Codex process.");
            IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the Codex app-server process.");
            try {
                int size = Marshal.SizeOf<PROCESS_BASIC_INFORMATION>();
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try {
                    int returned;
                    int status = NtQueryInformationProcess(process, 0, buffer, size, out returned);
                    if (status != 0) throw new Win32Exception(status, "NtQueryInformationProcess(ProcessBasicInformation) failed.");
                    var basic = Marshal.PtrToStructure<PROCESS_BASIC_INFORMATION>(buffer);
                    IntPtr parameters = ReadTargetPointer(process, IntPtr.Add(basic.PebBaseAddress, 0x20));
                    // RTL_USER_PROCESS_PARAMETERS on 64-bit Windows: stdin/stdout/stderr are
                    // at 0x20/0x28/0x30. The older winternl reserved-field sample obscures them.
                    IntPtr standardInput = ReadTargetPointer(process, IntPtr.Add(parameters, 0x20));
                    IntPtr standardOutput = ReadTargetPointer(process, IntPtr.Add(parameters, 0x28));
                    IntPtr standardError = ReadTargetPointer(process, IntPtr.Add(parameters, 0x30));
                    return new StandardHandleSet {
                        ProcessId = processId,
                        StandardInput = "0x" + standardInput.ToInt64().ToString("X"),
                        StandardOutput = "0x" + standardOutput.ToInt64().ToString("X"),
                        StandardError = "0x" + standardError.ToInt64().ToString("X")
                    };
                } finally { Marshal.FreeHGlobal(buffer); }
            } finally { CloseHandle(process); }
        }

        public static HandleRecord[] Inspect(int[] processIds, int[] parentProcessIds, string lockSuffix) {
            var wanted = new Dictionary<int, string>();
            foreach (var pid in processIds) wanted[pid] = "Codex app-server";
            foreach (var pid in parentProcessIds) if (!wanted.ContainsKey(pid)) wanted[pid] = "VS Code extension host";

            int length = 1 << 20;
            IntPtr systemBuffer = IntPtr.Zero;
            try {
                int needed;
                while (true) {
                    systemBuffer = Marshal.AllocHGlobal(length);
                    int status = NtQuerySystemInformation(SystemExtendedHandleInformation, systemBuffer, length, out needed);
                    if (status == 0) break;
                    Marshal.FreeHGlobal(systemBuffer); systemBuffer = IntPtr.Zero;
                    if (status != STATUS_INFO_LENGTH_MISMATCH) throw new Win32Exception(status, "NtQuerySystemInformation failed.");
                    length = Math.Max(length * 2, needed + 65536);
                }

                var header = Marshal.PtrToStructure<SYSTEM_HANDLE_INFORMATION_EX>(systemBuffer);
                long count = header.NumberOfHandles.ToInt64();
                int offset = Marshal.SizeOf<SYSTEM_HANDLE_INFORMATION_EX>();
                int entrySize = Marshal.SizeOf<SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX>();
                var records = new List<HandleRecord>();
                IntPtr currentProcess = GetCurrentProcess();
                var sourceProcesses = new Dictionary<int, IntPtr>();
                foreach (int pid in wanted.Keys) {
                    IntPtr source = OpenProcess(PROCESS_DUP_HANDLE, false, pid);
                    if (source != IntPtr.Zero) sourceProcesses[pid] = source;
                }

                try {
                    for (long index = 0; index < count; index++) {
                        IntPtr entryPointer = IntPtr.Add(systemBuffer, checked(offset + (int)(index * entrySize)));
                        var entry = Marshal.PtrToStructure<SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX>(entryPointer);
                        int pid = entry.UniqueProcessId.ToInt32();
                        string role;
                        IntPtr sourceProcess;
                        if (!wanted.TryGetValue(pid, out role) || !sourceProcesses.TryGetValue(pid, out sourceProcess)) continue;
                        IntPtr duplicate = IntPtr.Zero;
                        try {
                            if (!DuplicateHandle(sourceProcess, entry.HandleValue, currentProcess, out duplicate, 0, false, DUPLICATE_SAME_ACCESS)) continue;
                            uint type = GetFileType(duplicate);
                            if (type != FILE_TYPE_PIPE && (type != FILE_TYPE_DISK || String.IsNullOrEmpty(lockSuffix))) continue;
                            string name = type == FILE_TYPE_PIPE ? QueryObjectName(duplicate) : QueryFinalPath(duplicate);
                            bool isPipe = type == FILE_TYPE_PIPE && !String.IsNullOrWhiteSpace(name);
                            bool isTargetLock = type == FILE_TYPE_DISK && name.EndsWith(lockSuffix, StringComparison.OrdinalIgnoreCase);
                            if (!isPipe && !isTargetLock) continue;
                            records.Add(new HandleRecord {
                                ProcessId = pid,
                                Role = role,
                                Handle = "0x" + entry.HandleValue.ToInt64().ToString("X"),
                                Kind = isPipe ? "pipe" : "writer-lock",
                                Name = name,
                                Access = "0x" + entry.GrantedAccess.ToString("X8")
                            });
                        } finally {
                            if (duplicate != IntPtr.Zero) CloseHandle(duplicate);
                        }
                    }
                } finally {
                    foreach (IntPtr source in sourceProcesses.Values) CloseHandle(source);
                }
                return records.ToArray();
            } finally {
                if (systemBuffer != IntPtr.Zero) Marshal.FreeHGlobal(systemBuffer);
            }
        }

        public static HandleRecord[] InspectTargetProcesses(int[] processIds, int[] parentProcessIds, string lockSuffix, bool includePipes) {
            var wanted = new Dictionary<int, string>();
            foreach (var pid in processIds) wanted[pid] = "Codex app-server";
            foreach (var pid in parentProcessIds) if (!wanted.ContainsKey(pid)) wanted[pid] = "Host process";
            var records = new List<HandleRecord>();
            IntPtr currentProcess = GetCurrentProcess();
            int entrySize = Marshal.SizeOf<PROCESS_HANDLE_TABLE_ENTRY_INFO>();

            foreach (var wantedProcess in wanted) {
                IntPtr sourceProcess = OpenProcess(PROCESS_DUP_HANDLE | PROCESS_QUERY_INFORMATION, false, wantedProcess.Key);
                if (sourceProcess == IntPtr.Zero) continue;
                try {
                    int length = 65536;
                    IntPtr buffer = IntPtr.Zero;
                    try {
                        int needed;
                        while (true) {
                            buffer = Marshal.AllocHGlobal(length);
                            int status = NtQueryInformationProcess(sourceProcess, ProcessHandleInformation, buffer, length, out needed);
                            if (status == 0) break;
                            Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero;
                            if (status != STATUS_INFO_LENGTH_MISMATCH) throw new Win32Exception(status, "NtQueryInformationProcess(ProcessHandleInformation) failed.");
                            length = Math.Max(length * 2, needed + 4096);
                        }
                        long count = Marshal.ReadIntPtr(buffer, 0).ToInt64();
                        int offset = IntPtr.Size * 2;
                        for (long index = 0; index < count; index++) {
                            IntPtr entryPointer = IntPtr.Add(buffer, checked(offset + (int)(index * entrySize)));
                            var entry = Marshal.PtrToStructure<PROCESS_HANDLE_TABLE_ENTRY_INFO>(entryPointer);
                            IntPtr duplicate = IntPtr.Zero;
                            try {
                                if (!DuplicateHandle(sourceProcess, entry.HandleValue, currentProcess, out duplicate, 0, false, DUPLICATE_SAME_ACCESS)) continue;
                                uint type = GetFileType(duplicate);
                                if ((type != FILE_TYPE_PIPE || !includePipes) && (type != FILE_TYPE_DISK || String.IsNullOrEmpty(lockSuffix))) continue;
                                string name = type == FILE_TYPE_PIPE ? QueryPipePeers(duplicate) : QueryFinalPath(duplicate);
                                bool isPipe = type == FILE_TYPE_PIPE;
                                bool isTargetLock = type == FILE_TYPE_DISK && name.EndsWith(lockSuffix, StringComparison.OrdinalIgnoreCase);
                                if (!isPipe && !isTargetLock) continue;
                                records.Add(new HandleRecord {
                                    ProcessId = wantedProcess.Key,
                                    Role = wantedProcess.Value,
                                    Handle = "0x" + entry.HandleValue.ToInt64().ToString("X"),
                                    Kind = isPipe ? "pipe" : "writer-lock",
                                    Name = name,
                                    Access = "0x" + entry.GrantedAccess.ToString("X8")
                                });
                            } finally {
                                if (duplicate != IntPtr.Zero) CloseHandle(duplicate);
                            }
                        }
                    } finally {
                        if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                    }
                } finally { CloseHandle(sourceProcess); }
            }
            return records.ToArray();
        }
    }
}
'@
}

$codexProcesses = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -ieq 'codex.exe' -and $_.CommandLine -match '\bapp-server\b'
}
if (-not $codexProcesses) { throw 'No Codex app-server process is running.' }

$lockRecords = [CodexGroupy.CodexPipeInspectorV1]::InspectTargetProcesses(
    [int[]]@($codexProcesses.ProcessId),
    [int[]]@(),
    (Join-Path $env:USERPROFILE ('.codex\thread-writer-locks\{0}.lock' -f $ThreadId)),
    $false
)

$owner = $lockRecords | Where-Object { $_.Kind -eq 'writer-lock' -and $_.Role -eq 'Codex app-server' }
if ($owner) {
    'Writer-lock owner:'
    $owner | Format-Table ProcessId,Role,Handle,Name -AutoSize
}
else {
    throw 'No selected app-server holds the requested writer lock.'
}

$ownerPid = [int]$owner[0].ProcessId
$ownerProcess = $codexProcesses | Where-Object { $_.ProcessId -eq $ownerPid } | Select-Object -First 1
'Live writer standard handles (read-only):'
[CodexGroupy.CodexPipeInspectorV1]::GetStandardHandles($ownerPid) | Format-List

if (-not $MapPipes) {
    'Run again with -MapPipes to inspect the private pipe endpoints after the lock owner is known.'
    return
}

'Mapping only the lock owner and its direct host-process parent:'
$records = [CodexGroupy.CodexPipeInspectorV1]::InspectTargetProcesses(
    [int[]]@($ownerPid),
    [int[]]@([int]$ownerProcess.ParentProcessId),
    '',
    $true
)

'Potential app-server pipe endpoints and their parent extension-host endpoints:'
$records | Where-Object { $_.Kind -eq 'pipe' } | Sort-Object Name,ProcessId | Format-Table ProcessId,Role,Handle,Access,Name -AutoSize
