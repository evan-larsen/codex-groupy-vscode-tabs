[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Preview
)

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'projects.json' }

function Read-ProjectConfig {
    param([string]$Path)
    $config = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (@($config.projects).Count -eq 0 -or @($config.presets).Count -eq 0) {
        throw 'projects.json must contain at least one project and one preset.'
    }
    foreach ($project in $config.projects) {
        if ($project -isnot [string] -or [string]::IsNullOrWhiteSpace($project) -or
            -not [IO.Path]::IsPathRooted($project)) { throw 'Project paths must be absolute folder paths.' }
    }
    foreach ($preset in $config.presets) {
        if ([string]::IsNullOrWhiteSpace($preset.name) -or [string]::IsNullOrWhiteSpace($preset.model) -or
            $preset.effort -notin @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')) {
            throw 'Each preset needs a name, model, and supported effort.'
        }
    }
    return $config
}

function Get-ProjectPickerAction {
    param([string]$Key)
    switch ($Key) {
        { $_ -in 'W', 'UpArrow' } { return 'up' }
        { $_ -in 'S', 'DownArrow' } { return 'down' }
        { $_ -in 'A', 'LeftArrow' } { return 'left' }
        { $_ -in 'D', 'RightArrow' } { return 'right' }
        { $_ -in 'E', 'Enter' } { return 'launch' }
        'Escape' { return 'quit' }
        default { return 'none' }
    }
}

function Get-WrappedIndex {
    param([int]$Index, [int]$Delta, [int]$Count)
    return (($Index + $Delta + $Count) % $Count)
}

function Get-ProjectLaunchArguments {
    param([string]$Project, $Preset)
    # Pass an argument array directly. Never evaluate folder paths as shell code.
    return @('-C', $Project, '-m', $Preset.model, '-c', ('model_reasoning_effort="{0}"' -f $Preset.effort))
}

function Show-ProjectPicker {
    param($Config, [int]$ProjectIndex, [int]$PresetIndex, [string]$Message, [switch]$Plain)
    $preset = $Config.presets[$PresetIndex]
    $selected = $Config.projects[$ProjectIndex]
    $rows = @('', '  CODEX PROJECTS', '',
        ('  Preset    A <  {0} / {1}  > D' -f $preset.name, $preset.effort), '')
    # Scroll a long list to keep the selected row and footer visible.
    $visibleCount = if ($Plain) { @($Config.projects).Count } else { [Math]::Max(1, [Console]::WindowHeight - 13) }
    $first = [Math]::Max(0, $ProjectIndex - $visibleCount + 1)
    $last = [Math]::Min(@($Config.projects).Count - 1, $first + $visibleCount - 1)
    for ($i = $first; $i -le $last; $i++) {
        $name = Split-Path -Leaf ($Config.projects[$i].TrimEnd('\', '/'))
        $marker = if ($i -eq $ProjectIndex) { '>' } else { ' ' }
        $rows += ('  {0} {1}' -f $marker, $name)
    }
    $rows += @('', ('  {0}' -f $selected), '', '  W/S Move    A/D Preset    E Open    Esc Quit', ('  {0}' -f $Message))
    if ($Plain) { $rows | ForEach-Object { Write-Host $_ }; return }
    [Console]::SetCursorPosition(0, 0)
    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    $height = [Math]::Max(1, [Console]::WindowHeight - 1)
    for ($row = 0; $row -lt $height; $row++) {
        $line = if ($row -lt $rows.Count) { $rows[$row] } else { '' }
        if ($line.Length -gt $width) { $line = $line.Substring(0, [Math]::Max(0, $width - 3)) + '...' }
        if ($row -eq (5 + $ProjectIndex - $first)) {
            Write-Host $line.PadRight($width) -ForegroundColor Black -BackgroundColor Cyan
        } elseif ($row -eq 3) {
            Write-Host $line.PadRight($width) -ForegroundColor Cyan
        } else {
            Write-Host $line.PadRight($width)
        }
    }
}

function Start-CodexProjects {
    param([string]$Path, [switch]$Plain)
    $config = Read-ProjectConfig $Path
    $projectIndex = 0
    $presetIndex = 0
    $stateDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'codex-projects'
    $statePath = Join-Path $stateDirectory 'state.json'
    try {
        $saved = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        for ($i = 0; $i -lt @($config.presets).Count; $i++) {
            if ($config.presets[$i].model -eq $saved.model -and $config.presets[$i].effort -eq $saved.effort) { $presetIndex = $i; break }
        }
    } catch { } # Missing or stale local state never blocks the launcher.
    if ($Plain) { Show-ProjectPicker $config $projectIndex $presetIndex '' -Plain; return }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Run codex-projects in an interactive PowerShell terminal (or use -Preview).'
    }
    $cursorVisible = [Console]::CursorVisible
    $controlC = [Console]::TreatControlCAsInput
    $launchProject = $null
    $message = ''
    try {
        [Console]::CursorVisible = $false
        [Console]::TreatControlCAsInput = $true
        Clear-Host
        while ($true) {
            Show-ProjectPicker $config $projectIndex $presetIndex $message
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { break }
            $action = Get-ProjectPickerAction ([string]$key.Key)
            $message = ''
            switch ($action) {
                'up' { $projectIndex = Get-WrappedIndex $projectIndex -1 @($config.projects).Count }
                'down' { $projectIndex = Get-WrappedIndex $projectIndex 1 @($config.projects).Count }
                'left' { $presetIndex = Get-WrappedIndex $presetIndex -1 @($config.presets).Count }
                'right' { $presetIndex = Get-WrappedIndex $presetIndex 1 @($config.presets).Count }
                'launch' {
                    $candidate = $config.projects[$projectIndex]
                    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { $message = 'Folder missing. Edit projects.json to update its path.' }
                    elseif (-not (Get-Command codex -ErrorAction SilentlyContinue)) { $message = 'codex was not found on PATH. Install Codex CLI first.' }
                    else { $launchProject = $candidate }
                }
            }
            if ($action -eq 'quit' -or $null -ne $launchProject) { break }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
        [Console]::TreatControlCAsInput = $controlC
        Clear-Host
    }
    if ($null -eq $launchProject) { return }
    $preset = $config.presets[$presetIndex]
    try {
        New-Item -ItemType Directory -Path $stateDirectory -Force -ErrorAction Stop | Out-Null
        @{ model = $preset.model; effort = $preset.effort } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Warning 'Could not remember the preset; launching anyway.' }
    $launchArguments = Get-ProjectLaunchArguments $launchProject $preset
    & codex @launchArguments
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-CodexProjects -Path $ConfigPath -Plain:$Preview
}
