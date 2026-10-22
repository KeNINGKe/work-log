[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [switch]$DeleteInput,

    [string]$OutputDirectoryOverride
)

$ErrorActionPreference = 'Stop'

function Read-Utf8Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Write-Utf8NoBomAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $tempPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Normalize-Line {
    param($Text)
    if ($null -eq $Text) { return '' }
    return (($Text.ToString() -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim())
}

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

$skillRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $skillRoot 'references\config.json'
$config = Read-Utf8Json -Path $configPath
$payload = Read-Utf8Json -Path $InputFile

$outputRoot = Normalize-Line $OutputDirectoryOverride
if ([string]::IsNullOrWhiteSpace($outputRoot)) {
    $outputRoot = Normalize-Line (Get-PropertyValue $config 'output_directory')
}
if ([string]::IsNullOrWhiteSpace($outputRoot)) {
    throw 'The work-log output directory is not configured.'
}
[System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null

$date = Normalize-Line (Get-PropertyValue $payload 'date')
if ([string]::IsNullOrWhiteSpace($date)) { $date = Get-Date -Format 'yyyy-MM-dd' }
try {
    [void][DateTime]::ParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}
catch {
    throw "Invalid date '$date'. Expected yyyy-MM-dd."
}

$dataDirectoryName = Normalize-Line (Get-PropertyValue $config 'data_directory' '.work-log-data')
$dataRoot = Join-Path $outputRoot $dataDirectoryName
$dayDataRoot = Join-Path $dataRoot $date
[System.IO.Directory]::CreateDirectory($dayDataRoot) | Out-Null

$lockPath = Join-Path $dataRoot '.write.lock'
$lock = $null
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ($null -eq $lock -and [DateTime]::UtcNow -lt $deadline) {
    try {
        $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch [System.IO.IOException] {
        Start-Sleep -Milliseconds 100
    }
}
if ($null -eq $lock) { throw 'Could not acquire the work-log write lock.' }

try {
    $source = Normalize-Line (Get-PropertyValue $payload 'source' 'agent')
    $sessionId = Normalize-Line (Get-PropertyValue $payload 'session_id')
    $cwd = Normalize-Line (Get-PropertyValue $payload 'cwd')
    $entryId = Normalize-Line (Get-PropertyValue $payload 'entry_id')
    if ([string]::IsNullOrWhiteSpace($entryId)) {
        if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
            $entryId = "$source|$sessionId"
        }
        else {
            $entryId = "$source|$date|$cwd"
        }
    }

    $cleanItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-PropertyValue $payload 'items' @())) {
        if ($null -eq $item) { continue }
        $title = Normalize-Line (Get-PropertyValue $item 'title')
        $key = Normalize-Line (Get-PropertyValue $item 'key')
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        if ([string]::IsNullOrWhiteSpace($key)) { $key = "work:$($title.ToLowerInvariant())" }

        $points = New-Object System.Collections.Generic.List[string]
        $seenPoints = @{}
        foreach ($pointValue in @(Get-PropertyValue $item 'points' @())) {
            $point = Normalize-Line $pointValue
            if ([string]::IsNullOrWhiteSpace($point)) { continue }
            $pointKey = $point.ToLowerInvariant()
            if (-not $seenPoints.ContainsKey($pointKey)) {
                $seenPoints[$pointKey] = $true
                $points.Add($point)
            }
        }
        if ($points.Count -eq 0) { continue }

        $details = New-Object System.Collections.Generic.List[string]
        $seenDetails = @{}
        foreach ($detailValue in @(Get-PropertyValue $item 'details' @())) {
            $detail = Normalize-Line $detailValue
            if ([string]::IsNullOrWhiteSpace($detail)) { continue }
            $detailKey = $detail.ToLowerInvariant()
            if (-not $seenDetails.ContainsKey($detailKey)) {
                $seenDetails[$detailKey] = $true
                $details.Add($detail)
            }
        }
        if ($details.Count -eq 0) {
            foreach ($point in $points) { $details.Add($point) }
        }

        $cleanItems.Add([pscustomobject][ordered]@{
            key = $key.ToLowerInvariant()
            title = $title
            points = $points.ToArray()
            details = $details.ToArray()
        })
    }

    $savedFragment = $false
    if ($cleanItems.Count -gt 0) {
        $fragmentHash = Get-Sha256Text -Text $entryId
        $fragmentPath = Join-Path $dayDataRoot "$fragmentHash.json"
        $createdAt = [DateTime]::UtcNow.ToString('o')
        if (Test-Path -LiteralPath $fragmentPath) {
            try {
                $existing = Read-Utf8Json -Path $fragmentPath
                $existingCreatedAt = Normalize-Line (Get-PropertyValue $existing 'created_at')
                if (-not [string]::IsNullOrWhiteSpace($existingCreatedAt)) { $createdAt = $existingCreatedAt }
            }
            catch {
                $createdAt = [DateTime]::UtcNow.ToString('o')
            }
        }

        $fragment = [ordered]@{
            schema_version = 1
            entry_id = $entryId
            date = $date
            source = $source
            session_id = $sessionId
            cwd = $cwd
            created_at = $createdAt
            updated_at = [DateTime]::UtcNow.ToString('o')
            items = $cleanItems.ToArray()
        }
        Write-Utf8NoBomAtomic -Path $fragmentPath -Content ($fragment | ConvertTo-Json -Depth 12)
        $savedFragment = $true
    }

    $fragments = New-Object System.Collections.Generic.List[object]
    foreach ($fragmentFile in @(Get-ChildItem -LiteralPath $dayDataRoot -Filter '*.json' -File)) {
        try {
            $fragments.Add((Read-Utf8Json -Path $fragmentFile.FullName))
        }
        catch {
            continue
        }
    }
    $orderedFragments = @($fragments | Sort-Object { Normalize-Line (Get-PropertyValue $_ 'created_at') })

    $groups = [ordered]@{}
    foreach ($fragment in $orderedFragments) {
        foreach ($item in @(Get-PropertyValue $fragment 'items' @())) {
            $key = (Normalize-Line (Get-PropertyValue $item 'key')).ToLowerInvariant()
            $title = Normalize-Line (Get-PropertyValue $item 'title')
            if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($title)) { continue }
            if (-not $groups.Contains($key)) {
                $groups[$key] = [pscustomobject]@{
                    Title = $title
                    Points = (New-Object System.Collections.Generic.List[string])
                    Seen = @{}
                    Details = (New-Object System.Collections.Generic.List[string])
                    SeenDetails = @{}
                }
            }
            $group = $groups[$key]
            $group.Title = $title
            foreach ($pointValue in @(Get-PropertyValue $item 'points' @())) {
                $point = Normalize-Line $pointValue
                if ([string]::IsNullOrWhiteSpace($point)) { continue }
                $pointKey = $point.ToLowerInvariant()
                if (-not $group.Seen.ContainsKey($pointKey)) {
                    $group.Seen[$pointKey] = $true
                    $group.Points.Add($point)
                }
            }
            $itemDetails = @(Get-PropertyValue $item 'details' @())
            if ($itemDetails.Count -eq 0) { $itemDetails = @(Get-PropertyValue $item 'points' @()) }
            foreach ($detailValue in $itemDetails) {
                $detail = Normalize-Line $detailValue
                if ([string]::IsNullOrWhiteSpace($detail)) { continue }
                $detailKey = $detail.ToLowerInvariant()
                if (-not $group.SeenDetails.ContainsKey($detailKey)) {
                    $group.SeenDetails[$detailKey] = $true
                    $group.Details.Add($detail)
                }
            }
        }
    }

    if ($groups.Count -eq 0) {
        [Console]::Out.Write(([ordered]@{
            status = 'no_facts'
            date = $date
            log_path = $null
            message = 'No confirmed work facts were available, so no log file was generated.'
        } | ConvertTo-Json -Compress))
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]

    $topicNumber = 1
    # 简版要点不设条数上限（2026-09-08 用户要求取消每日 5 条与每主题条数限制），
    # 所有要点全部如实呈现；同一成果仍应合并为一条，避免同义重复。
    foreach ($groupKey in $groups.Keys) {
        $group = $groups[$groupKey]
        if ($group.Points.Count -le 0) { continue }
        $lines.Add("$topicNumber. $($group.Title)：")
        for ($index = 0; $index -lt $group.Points.Count; $index++) {
            $lines.Add("   $topicNumber.$($index + 1) $($group.Points[$index])")
        }
        $topicNumber++
    }

    $filePattern = Normalize-Line (Get-PropertyValue $config 'file_name_pattern' '{date}.md')
    $fileName = $filePattern.Replace('{date}', $date)
    $logPath = Join-Path $outputRoot $fileName
    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8NoBomAtomic -Path $logPath -Content $content

    $detailedLines = New-Object System.Collections.Generic.List[string]
    $detailedLines.Add("# $date 详细工作记录")
    $detailedLines.Add('')
    $detailedTopicNumber = 1
    foreach ($groupKey in $groups.Keys) {
        $group = $groups[$groupKey]
        $detailedLines.Add('')
        $detailedLines.Add("## $detailedTopicNumber. $($group.Title)")
        $detailedLines.Add('')
        for ($index = 0; $index -lt $group.Details.Count; $index++) {
            $detailedLines.Add("$detailedTopicNumber.$($index + 1) $($group.Details[$index])")
        }
        $detailedTopicNumber++
    }
    $detailedPattern = Normalize-Line (Get-PropertyValue $config 'detailed_file_name_pattern' '{date}_详细工作记录.md')
    $detailedFileName = $detailedPattern.Replace('{date}', $date)
    $detailedLogPath = Join-Path $outputRoot $detailedFileName
    $detailedContent = ($detailedLines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8NoBomAtomic -Path $detailedLogPath -Content $detailedContent

    [Console]::Out.Write(([ordered]@{
        status = if ($savedFragment) { 'saved' } else { 'rebuilt' }
        date = $date
        log_path = $logPath
        detailed_log_path = $detailedLogPath
        fragment_count = $orderedFragments.Count
        topic_count = $groups.Count
    } | ConvertTo-Json -Compress))
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if ($DeleteInput -and (Test-Path -LiteralPath $InputFile)) {
        Remove-Item -LiteralPath $InputFile -Force -ErrorAction SilentlyContinue
    }
}
