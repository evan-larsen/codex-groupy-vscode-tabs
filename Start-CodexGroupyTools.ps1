[CmdletBinding()]
param(
    # Report the supervisor and managed helpers that are already running, without starting anything.
    [switch]$Status,

    # Kept for compatibility. The supervisor now uses cached all-groups activity dots by default.
    [switch]$AllGroupsCachedActivityDots
)

$ErrorActionPreference = 'Stop'

$supervisor = Join-Path $PSScriptRoot 'CodexGroupySupervisor.ps1'
if (-not (Test-Path -LiteralPath $supervisor)) { throw "Missing supervisor: $supervisor" }

if ($Status) {
    & $supervisor -Status
    return
}

$repoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$runningSupervisor = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $commandLine = $_.CommandLine
    $commandLine -and
    $commandLine.IndexOf($repoRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $commandLine.IndexOf('CodexGroupySupervisor.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $commandLine.IndexOf('-Start', [StringComparison]::OrdinalIgnoreCase) -ge 0
})

if ($runningSupervisor.Count -gt 0) {
    Write-Host "Codex / Groupy supervisor is already running (PID $($runningSupervisor[0].ProcessId))."
    & $supervisor -Status
    return
}

$powershell = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $supervisor, '-Start') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
Start-Sleep -Milliseconds 800
Write-Host 'Codex / Groupy supervisor launched in the background.'
& $supervisor -Status
