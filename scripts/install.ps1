[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$userProfilePath = [Environment]::GetFolderPath('UserProfile')
$codexSkillPath = Join-Path $userProfilePath '.codex\skills\work-log'
$claudeSkillPath = Join-Path $userProfilePath '.claude\skills\work-log'
$codexHooksPath = Join-Path $userProfilePath '.codex\hooks.json'
$claudeSettingsPath = Join-Path $userProfilePath '.claude\settings.json'
$triggerScript = Join-Path $PSScriptRoot 'prompt_trigger.py'

function Write-Utf8NoBomAtomic {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $tempPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Read-JsonObject {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    return ($text | ConvertFrom-Json)
}

function Ensure-Property {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Ensure-Junction {
    param([string]$Path, [string]$Target)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $targets = @($item.Target)
        if ($targets -contains $Target) { return }
        throw "Refusing to replace existing skill path: $Path"
    }
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
}

function Add-UserPromptHook {
    param(
        $Root,
        [string]$Command,
        [string]$Needle,
        [switch]$IncludeWindowsOverride
    )
    $hooks = Ensure-Property -Object $Root -Name 'hooks' -Value ([pscustomobject]@{})
    $groups = @(Ensure-Property -Object $hooks -Name 'UserPromptSubmit' -Value @())
    foreach ($group in $groups) {
        if (($group | ConvertTo-Json -Depth 20 -Compress) -like "*$Needle*") { return $false }
    }

    $handler = [ordered]@{
        type = 'command'
        command = $Command
        timeout = 5
    }
    if ($IncludeWindowsOverride) {
        $handler['commandWindows'] = $Command
        $handler['statusMessage'] = 'Preparing work log'
    }
    $newGroup = [ordered]@{ hooks = @($handler) }
    $hooks.UserPromptSubmit = @($groups) + @($newGroup)
    return $true
}

Ensure-Junction -Path $codexSkillPath -Target $skillRoot
Ensure-Junction -Path $claudeSkillPath -Target $skillRoot

$codexRoot = Read-JsonObject -Path $codexHooksPath
if ($null -eq $codexRoot.PSObject.Properties['description']) {
    $codexRoot | Add-Member -NotePropertyName 'description' -NotePropertyValue 'Personal lifecycle hooks, including the shared work-log trigger.'
}
$codexCommand = 'python "' + $triggerScript + '" --source codex'
$codexChanged = Add-UserPromptHook -Root $codexRoot -Command $codexCommand -Needle 'prompt_trigger.py' -IncludeWindowsOverride
if ($codexChanged -or -not (Test-Path -LiteralPath $codexHooksPath)) {
    if (Test-Path -LiteralPath $codexHooksPath) {
        Copy-Item -LiteralPath $codexHooksPath -Destination "$codexHooksPath.work-log-backup" -Force
    }
    Write-Utf8NoBomAtomic -Path $codexHooksPath -Content ($codexRoot | ConvertTo-Json -Depth 30)
}

$claudeRoot = Read-JsonObject -Path $claudeSettingsPath
$claudeCommand = 'python "' + $triggerScript + '" --source claude'
$claudeChanged = Add-UserPromptHook -Root $claudeRoot -Command $claudeCommand -Needle 'prompt_trigger.py'
if ($claudeChanged) {
    if (Test-Path -LiteralPath $claudeSettingsPath) {
        Copy-Item -LiteralPath $claudeSettingsPath -Destination "$claudeSettingsPath.work-log-backup" -Force
    }
    Write-Utf8NoBomAtomic -Path $claudeSettingsPath -Content ($claudeRoot | ConvertTo-Json -Depth 50)
}

[Console]::Out.Write(([ordered]@{
    shared_skill = $skillRoot
    codex_skill = $codexSkillPath
    claude_skill = $claudeSkillPath
    codex_hook_updated = [bool]$codexChanged
    claude_hook_updated = [bool]$claudeChanged
} | ConvertTo-Json -Compress))
