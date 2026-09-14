[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string[]]$Overlay,
    [switch]$Apply,
    # Скрытые seams существуют только для детерминированных проверок состояния плана.
    [Parameter(DontShow = $true)][scriptblock]$TestBeforeApply,
    [Parameter(DontShow = $true)][scriptblock]$TestBeforeExistingMove
)

Set-StrictMode -Version Latest

Import-Module -Name (Join-Path $PSScriptRoot 'Governance.Common.psm1') -Force -ErrorAction Stop

$utf8 = [System.Text.UTF8Encoding]::new($false)
$rulesSource = 'https://github.com/dezrio1990/codex-development-system'
$semVerPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|([0-9]*[A-Za-z-][0-9A-Za-z-]*))(\.((0|[1-9][0-9]*)|([0-9]*[A-Za-z-][0-9A-Za-z-]*)))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\z'

function Test-ExactPath {
    param([string]$Left, [string]$Right)
    return [System.StringComparer]::OrdinalIgnoreCase.Equals(
        [System.IO.Path]::GetFullPath($Left).TrimEnd([char]92, [char]'/'),
        [System.IO.Path]::GetFullPath($Right).TrimEnd([char]92, [char]'/')
    )
}

function Test-PathInside {
    param([string]$Candidate, [string]$Container)
    if (Test-ExactPath $Candidate $Container) { return $true }
    $prefix = [System.IO.Path]::GetFullPath($Container).TrimEnd([char]92, [char]'/') + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Candidate).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoint {
    param([string]$Path)
    $current = [System.IO.Path]::GetFullPath($Path)
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Небезопасный reparse point: $current" }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or (Test-ExactPath $parent $current)) { return }
        $current = $parent
    }
}

function Assert-SafeProjectPath {
    param([string]$Path, [string]$Repository)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "ProjectPath должен быть существующим каталогом: $Path" }
    $root = [System.IO.Path]::GetPathRoot($full)
    $userHomePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (Test-ExactPath $full $root) { throw "Опасный ProjectPath: корень диска запрещён: $Path" }
    if (-not [string]::IsNullOrWhiteSpace($userHomePath) -and (Test-ExactPath $full $userHomePath)) { throw "Опасный ProjectPath: домашний каталог запрещён: $Path" }
    if ((Test-PathInside $full $Repository) -or (Test-PathInside $Repository $full)) { throw "Опасный ProjectPath: репозиторий и его предки/потомки запрещены: $Path" }
    Assert-NoReparsePoint $full
    return $full
}

function Get-Sha256 {
    param([byte[]]$Bytes)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    return $true
}

function Assert-StrictProperties {
    param($Object, [string[]]$Names, [string]$Description)
    $actual = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw "$Description содержит недопустимые поля." }
    foreach ($name in $Names) { if ($actual -cnotcontains $name) { throw "$Description не содержит поле $name." } }
}

function Get-VerifiedRelease {
    param([string]$Repository, [string]$RequestedVersion)
    $release = Get-GovernanceVersionPath -RepositoryRoot $Repository -Version $RequestedVersion
    if (-not (Test-Path -LiteralPath $release.FullName -PathType Container)) { throw "Опубликованный выпуск не найден: $RequestedVersion" }
    Assert-NoReparsePoint $release.FullName
    $versionPath = Join-Path $release.FullName 'version.json'
    $checksumsPath = Join-Path $release.FullName 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf) -or -not (Test-Path -LiteralPath $checksumsPath -PathType Leaf)) { throw 'Выпуск не содержит version.json или checksums.sha256.' }
    try { $metadata = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Некорректный version.json: $($_.Exception.Message)" }
    Assert-StrictProperties $metadata @('version', 'channel', 'gitTag', 'gitCommit', 'contentHash', 'releasedAt') 'version.json'
    if ($metadata.version -isnot [string] -or $metadata.version -cne $RequestedVersion -or $metadata.version -cnotmatch $semVerPattern) { throw 'version.json содержит неверную версию.' }
    if ($metadata.channel -cne 'stable' -or $metadata.gitTag -cne ('v' + $RequestedVersion)) { throw 'version.json содержит неверный channel или gitTag.' }
    if ($metadata.gitCommit -isnot [string] -or $metadata.gitCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'version.json содержит неверный gitCommit.' }
    if ($metadata.contentHash -isnot [string] -or $metadata.contentHash -cnotmatch '^[0-9a-f]{64}$') { throw 'version.json содержит неверный contentHash.' }
    try { [DateTimeOffset]::Parse($metadata.releasedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null }
    catch { throw 'version.json содержит неверный releasedAt.' }
    $actualHash = Get-GovernanceContentHash -RootPath $release.FullName
    if ($actualHash -cne $metadata.contentHash) { throw 'Content hash выпуска не совпадает с version.json.' }
    $expectedChecksums = @(Get-GovernanceChecksums -RootPath $release.FullName)
    $expectedBytes = $utf8.GetBytes((($expectedChecksums -join "`n") + "`n"))
    if (-not (Test-BytesEqual ([System.IO.File]::ReadAllBytes($checksumsPath)) $expectedBytes)) { throw 'Checksums выпуска не совпадают с фактическим payload или содержат unsafe/duplicate paths.' }
    $base = Join-Path $release.FullName 'templates/base'
    foreach ($required in @('AGENTS.md', '.codex/governance/README.md', 'docs/status/current.md', 'docs/plans/templates/active-plan.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $base $required) -PathType Leaf)) { throw "Неполный base template: отсутствует $required" }
    }
    return [PSCustomObject]@{ Path = $release.FullName; Metadata = $metadata; ContentHash = $actualHash; Base = $base }
}

function Get-CanonicalOverlays {
    param([string[]]$Requested, [string]$ReleasePath)
    if ($Requested.Count -eq 0) { throw 'Необходимо выбрать хотя бы один overlay.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [Collections.Generic.List[string]]::new()
    foreach ($name in $Requested) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name -cnotmatch '^[a-z0-9-]+$') { throw "Недопустимое имя overlay: $name" }
        if (-not $seen.Add($name)) { throw "Повторный overlay: $name" }
        $manifestPath = Join-Path $ReleasePath (Join-Path 'templates/overlays' (Join-Path $name 'overlay.json'))
        $appendPath = Join-Path $ReleasePath (Join-Path 'templates/overlays' (Join-Path $name 'AGENTS.append.md'))
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $appendPath -PathType Leaf)) { throw "Overlay не найден или неполон: $name" }
        try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Некорректный manifest overlay $name." }
        if ($manifest.name -isnot [string] -or $manifest.name -cne $name) { throw "Manifest overlay не совпадает с именем каталога: $name" }
        $names.Add($name)
    }
    $result = $names.ToArray()
    [Array]::Sort($result, [StringComparer]::OrdinalIgnoreCase)
    return @($result)
}

function Render-Markdown {
    param([byte[]]$Bytes, [hashtable]$Tokens, [string]$Source)
    $text = $utf8.GetString($Bytes)
    foreach ($key in $Tokens.Keys) { $text = $text.Replace('{{' + $key + '}}', [string]$Tokens[$key]) }
    if ($text -match '\{\{[^}]+\}\}') { throw "В Markdown остался неразрешённый токен: $Source" }
    return $utf8.GetBytes($text)
}

function New-Operation {
    param([string]$Target, [byte[]]$Bytes, [string]$Source, [byte[]]$SourceBytes, [string]$Timestamp)
    $exists = Test-Path -LiteralPath $Target
    if ($exists -and -not (Test-Path -LiteralPath $Target -PathType Leaf)) { throw "Конфликт destination не является файлом: $Target" }
    $backup = $null
    if ($exists) {
        $backup = $Target + '.backup-' + $Timestamp + '-' + [guid]::NewGuid().ToString('N')
        if (Test-Path -LiteralPath $backup) { throw "Резервная копия уже существует: $backup" }
    }
    return [PSCustomObject]@{ Target = $Target; Bytes = $Bytes; Source = $Source; SourceBytes = $SourceBytes; ExpectedExists = $exists; ExpectedBytes = if ($exists) { [IO.File]::ReadAllBytes($Target) } else { @() }; Backup = $backup }
}

function Get-InstalledHash {
    param([string]$BaseRules, [string[]]$OverlayFiles)
    $items = @([PSCustomObject]@{ Name = 'base-rules.md'; Path = $BaseRules })
    foreach ($file in $OverlayFiles) { $items += [PSCustomObject]@{ Name = 'overlays/' + (Split-Path -Leaf $file); Path = $file } }
    $items = @($items | Sort-Object -Property @{ Expression = { $_.Name }; Ascending = $true })
    foreach ($item in $items) { if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) { throw "Vendored rules не содержат $($item.Name)." } }
    $checksums = @($items | ForEach-Object { (Get-Sha256 ([IO.File]::ReadAllBytes($_.Path))) + '  ' + $_.Name })
    return Get-Sha256 $utf8.GetBytes(($checksums -join "`n") + "`n")
}

function Test-CurrentPin {
    param([string]$Project, $Release, [string[]]$Overlays)
    $manifestPath = Join-Path $Project '.codex/governance/manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Существующий manifest malformed. Используйте Sync-ProjectRules.ps1.' }
    try {
        Assert-StrictProperties $manifest @('schemaVersion', 'rulesSource', 'rulesVersion', 'rulesCommit', 'releaseContentHash', 'installedContentHash', 'overlays', 'installedAt', 'updatedAt') 'manifest'
        if ($manifest.schemaVersion -ne 1 -or $manifest.rulesSource -cne $rulesSource -or $manifest.rulesVersion -cne $Release.Metadata.version -or $manifest.rulesCommit -cne $Release.Metadata.gitCommit -or $manifest.releaseContentHash -cne $Release.ContentHash) { throw 'pin отличается' }
        $currentOverlays = @($manifest.overlays)
        if ($manifest.rulesCommit -isnot [string] -or $manifest.rulesCommit -cnotmatch '^[0-9a-f]{40}$' -or $manifest.releaseContentHash -isnot [string] -or $manifest.releaseContentHash -cnotmatch '^[0-9a-f]{64}$' -or $manifest.installedContentHash -isnot [string] -or $manifest.installedContentHash -cnotmatch '^[0-9a-f]{64}$') { throw 'manifest имеет неверные hash-поля' }
        try { [DateTimeOffset]::Parse($manifest.installedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null; [DateTimeOffset]::Parse($manifest.updatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null } catch { throw 'manifest имеет неверные даты' }
        foreach ($name in $currentOverlays) { if ($name -isnot [string] -or $name -cnotmatch '^[a-z0-9-]+$') { throw 'manifest имеет неверный overlay' } }
        if ($currentOverlays.Count -ne $Overlays.Count) { throw 'overlay отличается' }
        for ($i = 0; $i -lt $Overlays.Count; $i++) { if ($currentOverlays[$i] -cne $Overlays[$i]) { throw 'overlay отличается' } }
        $files = @($Overlays | ForEach-Object { Join-Path $Project ('.codex/governance/overlays/' + $_ + '.md') })
        $hash = Get-InstalledHash -BaseRules (Join-Path $Project '.codex/governance/base-rules.md') -OverlayFiles $files
        if ($manifest.installedContentHash -cne $hash) { throw 'vendored rules изменены' }
    }
    catch { throw 'Существующий manifest или vendored rules требуют Sync-ProjectRules.ps1.' }
    return $true
}

function Assert-OperationState {
    param($Operation)
    Assert-NoReparsePoint $Operation.Target
    if (-not [string]::IsNullOrEmpty($Operation.Source) -and -not (Test-BytesEqual ([IO.File]::ReadAllBytes($Operation.Source)) $Operation.SourceBytes)) { throw "Source snapshot изменился после плана: $($Operation.Source)" }
    $exists = Test-Path -LiteralPath $Operation.Target
    if ([bool]$exists -ne [bool]$Operation.ExpectedExists) { throw "Destination изменился после плана: $($Operation.Target)" }
    if ($exists -and -not (Test-BytesEqual ([IO.File]::ReadAllBytes($Operation.Target)) $Operation.ExpectedBytes)) { throw "Destination изменился после плана: $($Operation.Target)" }
}

function Write-Operation {
    param($Operation)
    $directory = Split-Path -Parent $Operation.Target
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    Assert-OperationState $Operation
    $temporary = Join-Path $directory ('.governance.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($Operation.Bytes, 0, $Operation.Bytes.Length) } finally { $stream.Dispose() }
        Assert-OperationState $Operation
        if (-not $Operation.ExpectedExists) { [IO.File]::Move($temporary, $Operation.Target); return }
        if ($null -ne $TestBeforeExistingMove) { & $TestBeforeExistingMove }
        Assert-OperationState $Operation
        [IO.File]::Move($Operation.Target, $Operation.Backup)
        if (-not (Test-BytesEqual ([IO.File]::ReadAllBytes($Operation.Backup)) $Operation.ExpectedBytes)) {
            if (-not (Test-Path -LiteralPath $Operation.Target)) { [IO.File]::Move($Operation.Backup, $Operation.Target) }
            throw "Destination изменился перед заменой; восстановлен: $($Operation.Target)"
        }
        [IO.File]::Move($temporary, $Operation.Target)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

$repository = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $repository -PathType Container)) { throw "RepositoryRoot не найден: $RepositoryRoot" }
Assert-NoReparsePoint $repository
$project = Assert-SafeProjectPath $ProjectPath $repository
$release = Get-VerifiedRelease $repository $Version
$overlays = Get-CanonicalOverlays $Overlay $release.Path

if (Test-CurrentPin $project $release $overlays) {
    Write-Output ([PSCustomObject]@{ Action = 'NoOp'; Reason = 'Текущий pin и vendored rules уже совпадают.' })
    return
}

$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture)
$installedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
$overlaysJson = ConvertTo-Json -InputObject @($overlays) -Compress
$tokens = @{ PROJECT_NAME = (Split-Path -Leaf $project); DATE = $installedAt.Substring(0, 10); RULES_VERSION = $Version; RULES_COMMIT = $release.Metadata.gitCommit; CONTENT_HASH = $release.ContentHash; OVERLAYS_JSON = $overlaysJson }
$operations = [Collections.Generic.List[object]]::new()
$baseFiles = @(Get-ChildItem -LiteralPath $release.Base -Recurse -File -Force)
foreach ($file in $baseFiles) {
    $relative = $file.FullName.Substring($release.Base.Length).TrimStart([char]92, [char]'/')
    if ($relative -ceq 'AGENTS.md') { continue }
    $sourceBytes = [IO.File]::ReadAllBytes($file.FullName)
    $bytes = if ($file.Extension -ceq '.md') { Render-Markdown $sourceBytes $tokens $file.FullName } else { $sourceBytes }
    $operations.Add((New-Operation (Join-Path $project $relative) $bytes $file.FullName $sourceBytes $timestamp))
}
$baseAgentsPath = Join-Path $release.Base 'AGENTS.md'
$baseAgentsBytes = [IO.File]::ReadAllBytes($baseAgentsPath)
$renderedBase = Render-Markdown $baseAgentsBytes $tokens $baseAgentsPath
$operations.Add((New-Operation (Join-Path $project '.codex/governance/base-rules.md') $renderedBase $baseAgentsPath $baseAgentsBytes $timestamp))
$rootLines = @('# Правила запуска проекта', '', 'Перед существенной работой обязательно прочитайте:', '- `.codex/governance/base-rules.md`.')
foreach ($name in $overlays) { $rootLines += '- `.codex/governance/overlays/' + $name + '.md`.' }
$rootLines += @('', 'Эти закреплённые правила дополняют существующие применимые правила и не отменяют их.')
$operations.Add((New-Operation (Join-Path $project 'AGENTS.md') $utf8.GetBytes(($rootLines -join "`n") + "`n") $baseAgentsPath $baseAgentsBytes $timestamp))
foreach ($name in $overlays) {
    $source = Join-Path $release.Path ('templates/overlays/' + $name + '/AGENTS.append.md')
    $sourceBytes = [IO.File]::ReadAllBytes($source)
    $target = Join-Path $project ('.codex/governance/overlays/' + $name + '.md')
    $operations.Add((New-Operation $target (Render-Markdown $sourceBytes $tokens $source) $source $sourceBytes $timestamp))
}
# Hash собирается из окончательных плановых байтов без записи во временные каталоги.
$hashItems = @([PSCustomObject]@{ Name = 'base-rules.md'; Bytes = $renderedBase })
foreach ($name in $overlays) { $hashItems += [PSCustomObject]@{ Name = 'overlays/' + $name + '.md'; Bytes = @($operations | Where-Object { $_.Target -ceq (Join-Path $project ('.codex/governance/overlays/' + $name + '.md')) })[0].Bytes } }
$hashLines = @($hashItems | Sort-Object Name | ForEach-Object { (Get-Sha256 $_.Bytes) + '  ' + $_.Name })
$installedHash = Get-Sha256 $utf8.GetBytes(($hashLines -join "`n") + "`n")
$manifest = [ordered]@{ schemaVersion = 1; rulesSource = $rulesSource; rulesVersion = $Version; rulesCommit = $release.Metadata.gitCommit; releaseContentHash = $release.ContentHash; installedContentHash = $installedHash; overlays = @($overlays); installedAt = $installedAt; updatedAt = $installedAt } | ConvertTo-Json -Depth 4
$operations.Add((New-Operation (Join-Path $project '.codex/governance/manifest.json') $utf8.GetBytes($manifest + "`n") $null $null $timestamp))

$plan = @($operations | Sort-Object Target | ForEach-Object { [PSCustomObject]@{ Action = if ($_.ExpectedExists) { 'BackupAndWrite' } else { 'Write' }; Target = $_.Target; Backup = $_.Backup } })
if (-not $Apply) { Write-Output $plan; return }
if ($null -ne $TestBeforeApply) { & $TestBeforeApply }
foreach ($operation in $operations) { Write-Operation $operation }
Write-Output $plan
