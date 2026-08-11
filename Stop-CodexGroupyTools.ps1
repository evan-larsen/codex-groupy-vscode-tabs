[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

$supervisor = Join-Path $PSScriptRoot 'CodexGroupySupervisor.ps1'
if (-not (Test-Path -LiteralPath $supervisor)) { throw "Missing supervisor: $supervisor" }

if ($PSCmdlet.ShouldProcess('Codex / Groupy supervisor and managed helpers', 'Stop')) {
    & $supervisor -Stop
}
