[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Start')]
    [switch]$Start,

    [Parameter(ParameterSetName = 'Stop')]
    [switch]$Stop,

    [Parameter(ParameterSetName = 'Restart')]
    [switch]$Restart,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'InstallTask')]
    [switch]$InstallStartupTask,

    [Parameter(ParameterSetName = 'UninstallTask')]
    [switch]$UninstallStartupTask,

    [ValidateRange(3, 60)]
    [int]$CheckIntervalSeconds = 8,

    [string]$TaskName = 'CodexGroupySupervisor'
)

$ErrorActionPreference = 'Stop'

$scriptRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$repoRoot = (Split-Path -Path $scriptRoot -Parent)
$workDir = Join-Path $repoRoot 'work'
if (-not (Test-Path -LiteralPath $workDir)) { [void](New-Item -ItemType Directory -Path $workDir -Force) }
$logPath = Join-Path $workDir 'CodexGroupySupervisor.log'
$powerShellExe = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source

$helpers = @(
    [pscustomobject]@{ Name = 'Codex tab-title sync'; Script = 'CodexGroupyTabSync.ps1'; Arguments = @('-WatchAutoTitle') },
    [pscustomobject]@{ Name = 'Codex chat rename Ctrl+Shift+R'; Script = 'CodexChatRenameHotkey.ps1'; Arguments = @() },
    [pscustomobject]@{ Name = 'Groupy Ctrl+1 through Ctrl+9'; Script = 'GroupyNumberTabs.ps1'; Arguments = @() },
    [pscustomobject]@{ Name = 'Separate-group Ctrl+Shift+N'; Script = 'GroupySeparateWindowHotkey.ps1'; Arguments = @() },
    [pscustomobject]@{ Name = 'Usage/context overlay'; Script = 'GroupyUsageOverlay.ps1'; Arguments = @() },
    [pscustomobject]@{ Name = 'Codex activity dots'; Script = 'GroupyCodexActivityDots.ps1'; Arguments = @('-AllGroupsCached') }
)

function Write-SupervisorLog([string]$Message) {
    $line = '[{0:yyyy-MM-dd HH:mm:ss.fff}] {1}' -f (Get-Date), $Message
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}
}

function Get-ResolvedHelpers {
    foreach ($helper in $helpers) {
        $path = Join-Path $scriptRoot $helper.Script
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing helper: $path" }
        [pscustomObject]@{
            Name = $helper.Name
            Script = $helper.Script
            Path = (Resolve-Path -LiteralPath $path).Path
            Arguments = $helper.Arguments
        }
    }
}

function Get-RunningHelper([string]$ScriptPath) {
    $root = Split-Path -Path $ScriptPath -Parent
    $scriptName = Split-Path -Path $ScriptPath -Leaf
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $commandLine = $_.CommandLine
        $commandLine -and
        $_.ProcessId -ne $PID -and
        $commandLine.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $commandLine.IndexOf($scriptName, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

function Get-RunningSupervisor {
    $scriptName = Split-Path -Path $PSCommandPath -Leaf
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $commandLine = $_.CommandLine
        $commandLine -and
        $_.ProcessId -ne $PID -and
        $commandLine.IndexOf($repoRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $commandLine.IndexOf($scriptName, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $commandLine.IndexOf('-Start', [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

function Start-Helper([pscustomobject]$Helper) {
    $running = @(Get-RunningHelper $Helper.Path)
    if ($running.Count -gt 0) { return $running[0] }

    $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $Helper.Path) + $Helper.Arguments
    $process = Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru
    Write-SupervisorLog "$($Helper.Name): started PID $($process.Id) ($($Helper.Script) $($Helper.Arguments -join ' '))."
    return $process
}

function Stop-Helper([pscustomobject]$Helper) {
    $running = @(Get-RunningHelper $Helper.Path)
    foreach ($process in $running) {
        try {
            Stop-Process -Id $process.ProcessId -ErrorAction Stop
            Write-SupervisorLog "$($Helper.Name): stopped PID $($process.ProcessId)."
        }
        catch {
            Write-SupervisorLog "$($Helper.Name): failed to stop PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Start-AllHelpers {
    foreach ($helper in Get-ResolvedHelpers) {
        [void](Start-Helper $helper)
    }
}

function Stop-AllHelpers {
    foreach ($helper in Get-ResolvedHelpers) {
        Stop-Helper $helper
    }
}

function Show-Status {
    $supervisors = @(Get-RunningSupervisor)
    $rows = @(
        [pscustomobject]@{
            Component = 'Codex / Groupy supervisor'
            Status = if ($supervisors.Count -gt 0) { 'running' } else { 'stopped' }
            Pid = if ($supervisors.Count -gt 0) { ($supervisors.ProcessId -join ', ') } else { $null }
        }
    )
    foreach ($helper in Get-ResolvedHelpers) {
        $running = @(Get-RunningHelper $helper.Path)
        $rows += [pscustomobject]@{
            Component = $helper.Name
            Status = if ($running.Count -gt 0) { 'running' } else { 'stopped' }
            Pid = if ($running.Count -gt 0) { ($running.ProcessId -join ', ') } else { $null }
        }
    }
    $rows | Format-Table -AutoSize

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        [pscustomobject]@{
            StartupTask = $task.TaskName
            State = $task.State
            TaskPath = $task.TaskPath
        } | Format-List
    }
    catch {
        [pscustomobject]@{
            StartupTask = $TaskName
            State = 'not registered'
            TaskPath = $null
        } | Format-List
    }
}

function Install-StartupTask {
    $startWrapperPath = Join-Path $scriptRoot 'Start-CodexGroupyTools.ps1'
    if (-not (Test-Path -LiteralPath $startWrapperPath)) { throw "Missing startup wrapper: $startWrapperPath" }
    $scriptPath = (Resolve-Path -LiteralPath $startWrapperPath).Path
    $argument = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $scriptPath
    $action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $argument -WorkingDirectory $repoRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Launches the detached Groupy/Codex helper supervisor for tab titles, activity dots, hotkeys, and overlays.'
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    Write-SupervisorLog "Installed Scheduled Task '$TaskName' for user $userId."
    Write-Host "Installed Scheduled Task '$TaskName'."
}

function Uninstall-StartupTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-SupervisorLog "Uninstalled Scheduled Task '$TaskName'."
        Write-Host "Uninstalled Scheduled Task '$TaskName'."
    }
    else {
        Write-Host "Scheduled Task '$TaskName' is not registered."
    }
}

if ($InstallStartupTask) {
    Install-StartupTask
    return
}

if ($UninstallStartupTask) {
    Uninstall-StartupTask
    return
}

if ($Stop) {
    Stop-AllHelpers
    foreach ($supervisor in Get-RunningSupervisor) {
        try {
            Stop-Process -Id $supervisor.ProcessId -ErrorAction Stop
            Write-SupervisorLog "Stopped supervisor PID $($supervisor.ProcessId)."
        }
        catch {
            Write-SupervisorLog "Failed to stop supervisor PID $($supervisor.ProcessId): $($_.Exception.Message)"
        }
    }
    Show-Status
    return
}

if ($Restart) {
    Stop-AllHelpers
    Start-AllHelpers
    Show-Status
    return
}

if ($Status -or -not $Start) {
    Show-Status
    return
}

$existingSupervisors = @(Get-RunningSupervisor)
if ($existingSupervisors.Count -gt 0) {
    Write-SupervisorLog "Supervisor start skipped because another supervisor is already running: PID $($existingSupervisors.ProcessId -join ', ')."
    Write-Host "Codex / Groupy supervisor is already running (PID $($existingSupervisors[0].ProcessId))."
    return
}

Write-SupervisorLog "Supervisor started in $repoRoot with check interval ${CheckIntervalSeconds}s."
Write-Host 'Codex / Groupy supervisor is running. Press Ctrl+C to stop this supervisor process.'

try {
    while ($true) {
        foreach ($helper in Get-ResolvedHelpers) {
            $running = @(Get-RunningHelper $helper.Path)
            if ($running.Count -eq 0) {
                [void](Start-Helper $helper)
            }
            elseif ($running.Count -gt 1) {
                $keepers = @($running | Sort-Object ProcessId)
                $duplicateIds = @($keepers | Select-Object -Skip 1 | ForEach-Object { $_.ProcessId })
                foreach ($duplicateId in $duplicateIds) {
                    try {
                        Stop-Process -Id $duplicateId -ErrorAction Stop
                        Write-SupervisorLog "$($helper.Name): stopped duplicate PID $duplicateId."
                    }
                    catch {
                        Write-SupervisorLog "$($helper.Name): failed to stop duplicate PID ${duplicateId}: $($_.Exception.Message)"
                    }
                }
            }
        }
        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}
finally {
    Write-SupervisorLog 'Supervisor process exited.'
}
