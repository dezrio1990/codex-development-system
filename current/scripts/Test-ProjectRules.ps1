[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$RepositoryRoot,
    [switch]$Json
)

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'Governance.Common.psm1') -Force -ErrorAction Stop

$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:SemVerPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|([0-9]*[A-Za-z-][0-9A-Za-z-]*))(\.((0|[1-9][0-9]*)|([0-9]*[A-Za-z-][0-9A-Za-z-]*)))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\z'
$script:RulesSource = 'https://github.com/dezrio1990/codex-development-system'

function New-Diagnostic {
    param([string]$Code, [string]$Path, [string]$Message)
    return [PSCustomObject][ordered]@{ code = $Code; path = $Path; message = $Message }
}

function Add-Diagnostic {
    param($List, [string]$Code, [string]$Path, [string]$Message)
    $List.Add((New-Diagnostic $Code $Path $Message)) | Out-Null
}

function Sort-Diagnostics {
    param([object[]]$Items)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        $insertAt = $result.Count
        for ($index = 0; $index -lt $result.Count; $index++) {
            $comparison = [StringComparer]::Ordinal.Compare($item.code, $result[$index].code)
            if ($comparison -eq 0) { $comparison = [StringComparer]::Ordinal.Compare($item.path, $result[$index].path) }
            if ($comparison -eq 0) { $comparison = [StringComparer]::Ordinal.Compare($item.message, $result[$index].message) }
            if ($comparison -lt 0) { $insertAt = $index; break }
        }
        $result.Insert($insertAt, $item)
    }
    return @($result)
}

function Test-AsciiMatch {
    param([string]$Value, [string]$Pattern)
    return [Regex]::IsMatch($Value, $Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Get-Sha256 {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Test-ByteArrayEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    return $true
}

function Test-PathInside {
    param([string]$Path, [string]$Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([char]92, [char]'/')
    return $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RawJsonString {
    param([string]$Text, [string]$Name)
    if ($Text.Contains([char]92)) { throw 'JSON с escape-последовательностями не поддерживает строгую проверку метаданных.' }
    $token = '"' + [Regex]::Escape($Name) + '"'
    if ([Regex]::Matches($Text, $token).Count -ne 1) { throw "Поле $Name должно встретиться ровно один раз." }
    $match = [Regex]::Match($Text, $token + '\s*:\s*"([^"\\]*)"')
    if (-not $match.Success) { throw "Поле $Name должно быть JSON-строкой." }
    return $match.Groups[1].Value
}

function Test-Rfc3339 {
    param([string]$Value)
    if (-not (Test-AsciiMatch $Value '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})\z')) { return $false }
    if (-not $Value.EndsWith('Z', [StringComparison]::Ordinal)) {
        $offset = $Value.Substring($Value.Length - 6)
        $hours = [int]$offset.Substring(1, 2); $minutes = [int]$offset.Substring(4, 2)
        if ($hours -gt 14 -or $minutes -gt 59 -or ($hours -eq 14 -and $minutes -ne 0)) { return $false }
    }
    try { [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null; return $true }
    catch { return $false }
}

function Test-StrictProperties {
    param($Object, [string[]]$Names)
    $actual = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { return $false }
    foreach ($name in $Names) { if ($actual -cnotcontains $name) { return $false } }
    return $true
}

function Test-Manifest {
    param([string]$ManifestPath)
    $result = [PSCustomObject]@{ Valid = $false; Manifest = $null; Message = '' }
    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop
        $installedAt = Get-RawJsonString $raw 'installedAt'; $updatedAt = Get-RawJsonString $raw 'updatedAt'
        $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-StrictProperties $manifest @('schemaVersion', 'rulesSource', 'rulesVersion', 'rulesCommit', 'releaseContentHash', 'installedContentHash', 'overlays', 'installedAt', 'updatedAt'))) { throw 'Набор полей manifest не соответствует контракту.' }
        $integer = $manifest.schemaVersion -is [byte] -or $manifest.schemaVersion -is [int16] -or $manifest.schemaVersion -is [int32] -or $manifest.schemaVersion -is [int64]
        if (-not $integer -or $manifest.schemaVersion -ne 1) { throw 'schemaVersion должен быть integer 1.' }
        if ($manifest.rulesSource -isnot [string] -or $manifest.rulesSource -cne $script:RulesSource) { throw 'rulesSource не соответствует центральному репозиторию.' }
        if ($manifest.rulesVersion -isnot [string] -or -not (Test-AsciiMatch $manifest.rulesVersion $script:SemVerPattern)) { throw 'rulesVersion должен быть SemVer.' }
        foreach ($property in @('rulesCommit', 'releaseContentHash', 'installedContentHash')) {
            $pattern = if ($property -ceq 'rulesCommit') { '^[0-9a-f]{40}\z' } else { '^[0-9a-f]{64}\z' }
            if ($manifest.$property -isnot [string] -or -not (Test-AsciiMatch $manifest.$property $pattern)) { throw "$property имеет неверный формат." }
        }
        if ($manifest.overlays -isnot [Array]) { throw 'overlays должен быть JSON-массивом.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($overlay in @($manifest.overlays)) {
            if ($overlay -isnot [string] -or -not (Test-AsciiMatch $overlay '^[a-z0-9-]+\z') -or -not $seen.Add($overlay)) { throw 'overlays содержит небезопасное или повторное имя.' }
        }
        if (-not (Test-Rfc3339 $installedAt) -or -not (Test-Rfc3339 $updatedAt)) { throw 'installedAt и updatedAt должны быть raw RFC3339 date-time.' }
        $result.Valid = $true; $result.Manifest = $manifest
    }
    catch { $result.Message = $_.Exception.Message }
    return $result
}

function Test-Release {
    param([string]$Repository, $Manifest)
    $result = [PSCustomObject]@{ Exists = $false; Valid = $false; Path = $null; Message = '' }
    try {
        $release = Get-GovernanceVersionPath -RepositoryRoot $Repository -Version $Manifest.rulesVersion
        $result.Path = $release.FullName
        if (-not (Test-Path -LiteralPath $release.FullName -PathType Container)) { return $result }
        $result.Exists = $true
        $versionPath = Join-Path $release.FullName 'version.json'; $checksumsPath = Join-Path $release.FullName 'checksums.sha256'
        if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf) -or -not (Test-Path -LiteralPath $checksumsPath -PathType Leaf)) { throw 'Выпуск не содержит version.json или checksums.sha256.' }
        $raw = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8
        $releasedAt = Get-RawJsonString $raw 'releasedAt'; $metadata = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-StrictProperties $metadata @('version', 'channel', 'gitTag', 'gitCommit', 'contentHash', 'releasedAt'))) { throw 'version.json содержит недопустимые поля.' }
        if ($metadata.version -isnot [string] -or $metadata.version -cne $Manifest.rulesVersion -or -not (Test-AsciiMatch $metadata.version $script:SemVerPattern)) { throw 'version.json содержит неверную версию.' }
        if ($metadata.channel -isnot [string] -or $metadata.channel -cne 'stable' -or $metadata.gitTag -isnot [string] -or $metadata.gitTag -cne ('v' + $Manifest.rulesVersion)) { throw 'version.json содержит неверный channel или gitTag.' }
        if ($metadata.gitCommit -isnot [string] -or -not (Test-AsciiMatch $metadata.gitCommit '^[0-9a-f]{40}\z') -or $metadata.contentHash -isnot [string] -or -not (Test-AsciiMatch $metadata.contentHash '^[0-9a-f]{64}\z') -or -not (Test-Rfc3339 $releasedAt)) { throw 'version.json содержит неверные метаданные.' }
        $actualHash = Get-GovernanceContentHash -RootPath $release.FullName
        if ($actualHash -cne $metadata.contentHash -or $Manifest.releaseContentHash -cne $actualHash -or $Manifest.rulesCommit -cne $metadata.gitCommit) { throw 'Контрольная сумма или commit выпуска не совпадает с manifest.' }
        $checksums = @(Get-GovernanceChecksums -RootPath $release.FullName)
        if (-not (Test-ByteArrayEqual ([IO.File]::ReadAllBytes($checksumsPath)) $script:Utf8.GetBytes(($checksums -join "`n") + "`n"))) { throw 'checksums.sha256 не соответствует payload выпуска.' }
        $result.Valid = $true
    }
    catch { $result.Message = $_.Exception.Message }
    return $result
}

function Test-InstalledRules {
    param([string]$Project, $Manifest)
    try {
        $governance = Join-Path $Project '.codex/governance'; $base = Join-Path $governance 'base-rules.md'; $overlaysPath = Join-Path $governance 'overlays'
        $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $expected.Add('base-rules.md') | Out-Null
        foreach ($overlay in @($Manifest.overlays)) { $expected.Add('overlays/' + $overlay + '.md') | Out-Null }
        $actual = [Collections.Generic.List[object]]::new()
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $portableNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in @(Get-ChildItem -LiteralPath $governance -Recurse -File -Force -ErrorAction Stop)) {
            $relative = $file.FullName.Substring($governance.TrimEnd([char]92, [char]'/').Length).TrimStart([char]92, [char]'/').Replace([char]92, [char]'/')
            if ($relative -ceq 'manifest.json' -or $relative -ceq 'README.md') { continue }
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $names.Add($relative) -or -not $portableNames.Add($relative) -or -not $expected.Contains($relative)) { return $false }
            $actual.Add([PSCustomObject]@{ Name = $relative; Path = $file.FullName }) | Out-Null
        }
        if (-not (Test-Path -LiteralPath $base -PathType Leaf) -or $actual.Count -ne $expected.Count) { return $false }
        foreach ($name in $expected) { if (-not $names.Contains($name)) { return $false } }
        $items = @($actual); [Array]::Sort($items, [Comparison[object]]{ param($left, $right) [StringComparer]::Ordinal.Compare($left.Name, $right.Name) })
        $lines = foreach ($item in $items) { (Get-Sha256 ([IO.File]::ReadAllBytes($item.Path))) + '  ' + $item.Name }
        return $Manifest.installedContentHash -ceq (Get-Sha256 $script:Utf8.GetBytes(($lines -join "`n") + "`n"))
    }
    catch { return $false }
}

function Get-GovernedDocuments {
    param([string]$Project)
    $documents = [Collections.Generic.List[object]]::new()
    $rootAgents = Join-Path $Project 'AGENTS.md'
    if (Test-Path -LiteralPath $rootAgents -PathType Leaf) { $documents.Add([PSCustomObject]@{ Path = $rootAgents; IsRootAgents = $true }) | Out-Null }
    foreach ($root in @((Join-Path $Project '.codex/governance'), (Join-Path $Project 'docs'))) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' -Force)) { $documents.Add([PSCustomObject]@{ Path = $file.FullName; IsRootAgents = $false }) | Out-Null }
        }
    }
    return @($documents)
}

function Resolve-RequiredPath {
    # related с .codex/, docs/ или AGENTS.md трактуется от project root; остальные пути — от документа.
    param([string]$Project, [string]$Document, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or [Uri]::IsWellFormedUriString($Value, [UriKind]::Absolute) -or [IO.Path]::IsPathRooted($Value) -or $Value -match '(^|[\\/])\.\.([\\/]|$)' -or $Value -match '[:<>"|?*]') { return $null }
    $base = if ($Value -match '^(\.codex/|docs/|AGENTS\.md\z)') { $Project } else { Split-Path -Parent $Document }
    $candidate = [IO.Path]::GetFullPath((Join-Path $base $Value))
    if (-not (Test-PathInside $candidate $Project) -or -not (Test-NoReparsePathComponent $Project $candidate)) { return $null }
    return $candidate
}

function Test-NoReparsePathComponent {
    # Лексическая проверка пути недостаточна: junction/symlink может вывести
    # наружу после неё. Это проверка состояния, не handle-level TOCTOU защита.
    param([string]$Project, [string]$Candidate)
    try {
        $root = [IO.Path]::GetFullPath($Project).TrimEnd([char]92, [char]'/')
        $relative = [IO.Path]::GetFullPath($Candidate).Substring($root.Length).TrimStart([char]92, [char]'/')
        $current = $root
        foreach ($segment in ($relative -split '[\\/]')) {
            if ([string]::IsNullOrWhiteSpace($segment)) { continue }
            $current = Join-Path $current $segment
            if (-not (Test-Path -LiteralPath $current)) { break }
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-ExternalHttpRelated {
    param([string]$Value)
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $uri.Scheme -ceq 'http' -or $uri.Scheme -ceq 'https'
}

function Get-FrontMatter {
    param([string]$Text)
    if (-not $Text.StartsWith("---`n") -and -not $Text.StartsWith("---`r`n")) { return $null }
    $lines = $Text -split "`r?`n"; $end = -1
    for ($index = 1; $index -lt $lines.Count; $index++) { if ($lines[$index] -ceq '---') { $end = $index; break } }
    if ($end -lt 1) { throw 'Front matter не закрыт вторым разделителем ---.' }
    $values = @{}
    for ($index = 1; $index -lt $end; $index++) {
        $match = [Regex]::Match($lines[$index], '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*\z')
        if (-not $match.Success -or $values.ContainsKey($match.Groups[1].Value)) { throw 'Front matter содержит некорректное или повторное поле.' }
        $values[$match.Groups[1].Value] = $match.Groups[2].Value
    }
    return $values
}

function Test-Documents {
    param([string]$Project, $Errors, $Warnings)
    foreach ($document in @(Get-GovernedDocuments $Project)) {
        $text = Get-Content -LiteralPath $document.Path -Raw -Encoding UTF8
        try { $frontMatter = Get-FrontMatter $text }
        catch { Add-Diagnostic $Errors 'STATUS_INVALID' $document.Path "Некорректный front matter: $($_.Exception.Message)"; continue }
        if ($null -eq $frontMatter) {
            if (-not $document.IsRootAgents) { Add-Diagnostic $Errors 'STATUS_INVALID' $document.Path 'Управляемый документ не содержит front matter.' }
            continue
        }
        $status = $null
        $validStatus = $frontMatter.ContainsKey('status') -and $frontMatter.status -is [string] -and $frontMatter.status -cin @('Draft', 'In Review', 'Approved', 'Superseded', 'Archived')
        if (-not $validStatus) { Add-Diagnostic $Errors 'STATUS_INVALID' $document.Path 'status должен быть одним из Draft, In Review, Approved, Superseded, Archived.' } else { $status = $frontMatter.status }
        if ($status -ceq 'Approved' -and $text -match '(\{\{[^}]+\}\}|\bTODO\b|\bTBD\b|Не заполнено|Не назначен|\[заполнить\])') { Add-Diagnostic $Errors 'APPROVED_PLACEHOLDER' $document.Path 'Утверждённый документ содержит явный незаполненный marker.' }
        $required = [Collections.Generic.List[object]]::new()
        if ($frontMatter.ContainsKey('related')) { foreach ($value in ($frontMatter.related -split ';')) { if (-not [string]::IsNullOrWhiteSpace($value)) { $trimmed = $value.Trim(); if (-not (Test-ExternalHttpRelated $trimmed)) { $required.Add([PSCustomObject]@{ Value = $trimmed; IsRussianExplanation = $false }) | Out-Null } } } }
        if ($frontMatter.ContainsKey('russian_explanation')) { $required.Add([PSCustomObject]@{ Value = $frontMatter.russian_explanation.Trim(); IsRussianExplanation = $true }) | Out-Null }
        $russianTarget = $null
        foreach ($requiredLink in $required) {
            $target = Resolve-RequiredPath $Project $document.Path $requiredLink.Value
            if ($null -eq $target -or -not (Test-Path -LiteralPath $target)) { Add-Diagnostic $Errors 'BROKEN_REQUIRED_LINK' $document.Path "Обязательная ссылка недоступна или небезопасна: $($requiredLink.Value)" }
            elseif ($requiredLink.IsRussianExplanation) { $russianTarget = $target }
        }
        if ($text -notmatch '[\u0400-\u052F]') {
            if ($null -eq $russianTarget -or -not (Test-Path -LiteralPath $russianTarget -PathType Leaf) -or (Get-Content -LiteralPath $russianTarget -Raw -Encoding UTF8) -notmatch '[\u0400-\u052F]') { Add-Diagnostic $Errors 'RUSSIAN_EXPLANATION_MISSING' $document.Path 'Документ не содержит кириллицу и не имеет доступного русского пояснения.' }
        }
    }
    $active = Join-Path $Project 'docs/plans/active'
    $plans = @(if (Test-Path -LiteralPath $active -PathType Container) { @(Get-ChildItem -LiteralPath $active -File -Filter '*.md' | Where-Object { $_.Name -notmatch 'placeholder' }) } else { @() })
    if ($plans.Count -eq 0) { Add-Diagnostic $Warnings 'ACTIVE_PLAN_MISSING' $active 'Активный план отсутствует; это допустимо между этапами.' }
    $agents = @(Get-ChildItem -LiteralPath $Project -Recurse -File -Filter 'AGENTS.md' -Force | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|bin|obj)[\\/]' })
    foreach ($agent in $agents) { if ([IO.File]::ReadAllLines($agent.FullName).Count -gt 500) { Add-Diagnostic $Warnings 'AGENTS_TOO_LARGE' $agent.FullName 'AGENTS.md превышает мягкий порог 500 физических строк и требует анализа.' } }
}

$errors = [Collections.Generic.List[object]]::new(); $warnings = [Collections.Generic.List[object]]::new()
try {
    if ([string]::IsNullOrWhiteSpace($ProjectPath) -or [string]::IsNullOrWhiteSpace($RepositoryRoot) -or -not (Test-Path -LiteralPath $ProjectPath -PathType Container) -or -not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw 'ProjectPath и RepositoryRoot должны быть существующими каталогами.' }
    $project = [IO.Path]::GetFullPath($ProjectPath); $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $manifestPath = Join-Path $project '.codex/governance/manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Add-Diagnostic $errors 'MANIFEST_MISSING' $manifestPath 'Не найден manifest закреплённого набора правил.' }
    else {
        $manifestResult = Test-Manifest $manifestPath
        if (-not $manifestResult.Valid) { Add-Diagnostic $errors 'MANIFEST_INVALID' $manifestPath "Manifest не соответствует строгому контракту: $($manifestResult.Message)" }
        else {
            $release = Test-Release $repository $manifestResult.Manifest
            if (-not $release.Exists) { Add-Diagnostic $errors 'VERSION_NOT_FOUND' $release.Path "Не найден выпуск правил $($manifestResult.Manifest.rulesVersion)." }
            elseif (-not $release.Valid) { Add-Diagnostic $errors 'RELEASE_HASH_MISMATCH' $release.Path "Целостность выпуска не подтверждена: $($release.Message)" }
            if (-not (Test-InstalledRules $project $manifestResult.Manifest)) { Add-Diagnostic $errors 'INSTALLED_HASH_MISMATCH' (Join-Path $project '.codex/governance') 'Установленные vendored rules не совпадают с manifest или имеют небезопасный состав.' }
        }
    }
    Test-Documents $project $errors $warnings
}
catch { Add-Diagnostic $errors 'VALIDATION_INVOCATION' $ProjectPath "Невозможно выполнить проверку: $($_.Exception.Message)" }

$sortedErrors = @(Sort-Diagnostics @($errors)); $sortedWarnings = @(Sort-Diagnostics @($warnings))
$result = [PSCustomObject][ordered]@{ isValid = ($sortedErrors.Count -eq 0); errors = $sortedErrors; warnings = $sortedWarnings }
if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 5 -Compress)) }
else {
    if ($sortedErrors.Count -gt 0) { Write-Output 'Ошибки:'; foreach ($item in $sortedErrors) { Write-Output ("- [{0}] {1}: {2}" -f $item.code, $item.path, $item.message) } }
    if ($sortedWarnings.Count -gt 0) { Write-Output 'Предупреждения:'; foreach ($item in $sortedWarnings) { Write-Output ("- [{0}] {1}: {2}" -f $item.code, $item.path, $item.message) } }
    if ($sortedErrors.Count -eq 0) { Write-Output 'Итог: обязательных нарушений не найдено.' } else { Write-Output 'Итог: обнаружены обязательные нарушения.' }
}
if ($sortedErrors.Count -gt 0) { exit 1 }
