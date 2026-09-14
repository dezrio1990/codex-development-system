Set-StrictMode -Version Latest

$script:SemVerPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-((0|[1-9]\d*)|(\d*[A-Za-z-][0-9A-Za-z-]*))(\.((0|[1-9]\d*)|(\d*[A-Za-z-][0-9A-Za-z-]*)))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

function Get-GovernanceRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    $root = [System.IO.Path]::GetFullPath($RootPath)
    $file = [System.IO.Path]::GetFullPath($FilePath)
    $rootWithSeparator = $root.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar

    if (-not $file.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Файл находится вне корневого каталога: $FilePath"
    }

    return $file.Substring($rootWithSeparator.Length).Replace('\', '/')
}

function Assert-GovernanceUniqueRelativePaths {
    param([Parameter(Mandatory = $true)][string[]]$RelativePaths)

    $knownPaths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in $RelativePaths) {
        if ($knownPaths.ContainsKey($relativePath)) {
            throw "Нормализованные относительные пути конфликтуют: '$($knownPaths[$relativePath])' и '$relativePath'."
        }
        $knownPaths.Add($relativePath, $relativePath)
    }
}

function Get-GovernancePayloadFiles {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $root = [System.IO.Path]::GetFullPath($RootPath)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Каталог не найден: $RootPath"
    }

    $payloadFiles = [System.Collections.Generic.List[object]]::new()
    Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Name -notin @('version.json', 'checksums.sha256') } |
        ForEach-Object {
            $relativePath = Get-GovernanceRelativePath -RootPath $root -FilePath $_.FullName
            $payloadFiles.Add([PSCustomObject]@{
                File = $_
                RelativePath = $relativePath
            })
        }

    Assert-GovernanceUniqueRelativePaths -RelativePaths @($payloadFiles | ForEach-Object { $_.RelativePath })
    $payloadByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($payloadFile in $payloadFiles) {
        $payloadByPath.Add($payloadFile.RelativePath, $payloadFile)
    }
    $paths = [string[]]@($payloadByPath.Keys)
    [System.Array]::Sort($paths, [System.StringComparer]::OrdinalIgnoreCase)
    return @($paths | ForEach-Object { $payloadByPath[$_] })
}

function Get-GovernanceSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-GovernanceVersionPath {
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    if ($Version -notmatch $script:SemVerPattern) {
        throw "Версия должна быть SemVer без сегментов пути: $Version"
    }

    $repositoryPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $versionsPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryPath 'versions'))
    $versionPath = [System.IO.Path]::GetFullPath((Join-Path $versionsPath $Version))
    $prefix = $versionsPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

    if (-not $versionPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Путь версии должен находиться в каталоге versions: $Version"
    }

    return [System.IO.DirectoryInfo]::new($versionPath)
}

function Get-GovernanceManifest {
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $manifestPath = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex/governance/manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifest не найден: $manifestPath"
    }

    return (Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Get-GovernanceChecksums {
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $checksums = foreach ($payloadFile in Get-GovernancePayloadFiles -RootPath $RootPath) {
        $bytes = [System.IO.File]::ReadAllBytes($payloadFile.File.FullName)
        $hash = Get-GovernanceSha256 -Bytes $bytes
        "$hash  $($payloadFile.RelativePath)"
    }

    return @($checksums)
}

function Get-GovernanceContentHash {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $checksums = @(Get-GovernanceChecksums -RootPath $RootPath)
    # Кодировка без BOM нужна для одинакового хеша в разных PowerShell и ОС.
    $content = if ($checksums.Count -eq 0) { '' } else { ($checksums -join "`n") + "`n" }
    return Get-GovernanceSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($content))
}

function Copy-GovernanceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Replace
    )

    $sourcePath = [System.IO.Path]::GetFullPath($Source)
    $destinationPath = [System.IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Исходный файл не найден: $Source"
    }
    if ((Test-Path -LiteralPath $destinationPath -PathType Leaf) -and -not $Replace) {
        throw "Файл назначения уже существует: $Destination. Для замены передайте -Replace."
    }

    $destinationDirectory = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    [System.IO.File]::Copy($sourcePath, $destinationPath, [bool]$Replace)
}

Export-ModuleMember -Function Get-GovernanceVersionPath, Get-GovernanceManifest, Get-GovernanceChecksums, Get-GovernanceContentHash, Copy-GovernanceFile
