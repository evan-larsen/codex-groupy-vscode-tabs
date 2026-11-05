param([int]$ParentProcessId)

function ConvertTo-GroupyTitle([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $clean = ($Title -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 117).TrimEnd() + '...' }
    return $clean
}

function Get-CodexAutoTitleTarget([System.Windows.Automation.AutomationElement]$Root) {
    $documentCondition = [System.Windows.Automation.AndCondition]::new(@(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Document
        ),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, 'Codex'
        )
    ))
    $documents = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $documentCondition)
    $cache = [System.Windows.Automation.CacheRequest]::new()
    $cache.AutomationElementMode = [System.Windows.Automation.AutomationElementMode]::None
    $cache.Add([System.Windows.Automation.AutomationElement]::NameProperty)
    $cache.Add([System.Windows.Automation.AutomationElement]::ClassNameProperty)
    $cache.Add([System.Windows.Automation.AutomationElement]::ControlTypeProperty)

    $webview = $null
    foreach ($document in $documents) {
        $cache.Push()
        try {
            $elements = $document.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            )
        } finally {
            $cache.Pop()
        }

        $hasChatControls = $false
        foreach ($element in $elements) {
            $item = $element.Cached
            if ($item.Name -in @('Chats', 'New chat')) { $hasChatControls = $true }
            if ($item.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
                $item.ClassName -match 'flex-1\s+truncate' -and $item.ClassName -match 'text-start') {
                $title = ConvertTo-GroupyTitle $item.Name
                if ($title) { return [pscustomobject]@{ State = 'chat'; Title = $title } }
            }
        }
        if ($null -eq $webview -and $hasChatControls) { $webview = $elements }
    }

    if ($null -eq $webview) {
        return [pscustomobject]@{ State = 'closed'; Title = $null }
    }

    # When the header is unavailable, count title matches outside the sidebar in one pass.
    $sidebarTitles = [Collections.Generic.List[string]]::new()
    $outsideCounts = @{}
    foreach ($element in $webview) {
        $item = $element.Cached
        $title = ConvertTo-GroupyTitle $item.Name
        if (-not $title) { continue }
        if ($item.ClassName -match 'app-action-sidebar-thread') {
            if ($item.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
                $item.Name -notin @('New chat', 'Archive chat', 'Delete chat', 'Rename chat')) {
                $sidebarTitles.Add($title)
            }
        } else {
            $outsideCounts[$title] = 1 + [int]$outsideCounts[$title]
        }
    }
    $bestTitle = $null
    $bestScore = 0
    foreach ($title in $sidebarTitles) {
        if ([int]$outsideCounts[$title] -gt $bestScore) {
            $bestTitle = $title
            $bestScore = $outsideCounts[$title]
        }
    }
    if ($bestTitle) { return [pscustomobject]@{ State = 'chat'; Title = $bestTitle } }
    return [pscustomobject]@{ State = 'home'; Title = $null }
}

function Get-CodexActiveTitle([System.Windows.Automation.AutomationElement]$Root) {
    (Get-CodexAutoTitleTarget $Root).Title
}

function Get-CodeWorkspaceName([System.Windows.Automation.AutomationElement]$Root) {
    $explorerCondition = [System.Windows.Automation.AndCondition]::new(@(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Tree
        ),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, 'Files Explorer'
        )
    ))
    $explorer = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $explorerCondition)
    if ($explorer) {
        $itemCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TreeItem
        )
        $item = $explorer.FindFirst([System.Windows.Automation.TreeScope]::Children, $itemCondition)
        if ($item) { return ConvertTo-GroupyTitle $item.Current.Name }
    }
}

# Dot-sourcing makes the title readers available to the manual inspection modes.
if (-not $ParentProcessId) { return }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;

public static class CodexGroupyProbeLifetime {
    public static void ExitWithParent(int parentId) {
        var parent = Process.GetProcessById(parentId);
        var watcher = new Thread(() => {
            try { parent.WaitForExit(); }
            finally { Environment.Exit(0); }
        });
        watcher.IsBackground = true;
        watcher.Start();
    }
}
'@
[CodexGroupyProbeLifetime]::ExitWithParent($ParentProcessId)

while ($null -ne ($requestLine = [Console]::ReadLine())) {
    try {
        $request = ConvertFrom-Json -InputObject $requestLine
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$request.Handle)
        $target = Get-CodexAutoTitleTarget $root
        $workspace = if ($request.NeedWorkspace -and $target.State -ne 'chat') {
            Get-CodeWorkspaceName $root
        }
        $response = @{ State = $target.State; Title = $target.Title; Workspace = $workspace; Error = $null }
    } catch {
        $response = @{ Error = $_.Exception.GetType().Name }
    }
    [Console]::WriteLine(($response | ConvertTo-Json -Compress))
}
