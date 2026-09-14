[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$CodexHome
)

Set-StrictMode -Version Latest

$commonModulePath = Join-Path $PSScriptRoot 'Governance.Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

$expectedAgentNames = @(
    'android_developer.toml',
    'backend_architect.toml',
    'code_reviewer.toml',
    'debugger.toml',
    'dotnet_maui_developer.toml',
    'frontend_developer.toml',
    'ios_developer.toml',
    'ui_designer.toml',
    'ux_researcher.toml'
)
$beginMarker = '<!-- codex-development-system:begin -->'
$endMarker = '<!-- codex-development-system:end -->'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Test-ExactPath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [System.StringComparer]::OrdinalIgnoreCase.Equals(
        [System.IO.Path]::GetFullPath($Left).TrimEnd([char]'\', [char]'/'),
        [System.IO.Path]::GetFullPath($Right).TrimEnd([char]'\', [char]'/')
    )
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Container
    )

    if (Test-ExactPath -Left $Candidate -Right $Container) {
        return $true
    }

    $containerWithSeparator = [System.IO.Path]::GetFullPath($Container).TrimEnd([char]'\', [char]'/') + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Candidate).StartsWith($containerWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = [System.IO.Path]::GetFullPath($Path)
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Небезопасный reparse point в пути назначения: $current"
            }
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or (Test-ExactPath -Left $parent -Right $current)) {
            break
        }
        $current = $parent
    }
}

function Assert-SafeCodexHome {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryPath
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root) -or (Test-ExactPath -Left $fullPath -Right $root)) {
        throw "Опасная цель CodexHome: нельзя устанавливать в корень диска или UNC/share: $Path"
    }

    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($userHome) -and (Test-ExactPath -Left $fullPath -Right $userHome)) {
        throw "Опасная цель CodexHome: нельзя устанавливать в домашний каталог пользователя: $Path"
    }

    if ((Test-ExactPath -Left $fullPath -Right $RepositoryPath) -or (Test-PathInside -Candidate $RepositoryPath -Container $fullPath)) {
        throw "Опасная цель CodexHome: каталог репозитория и его предки запрещены: $Path"
    }

    Assert-NoReparsePoint -Path $fullPath
    return $fullPath
}

function Find-ByteSequence {
    param(
        [AllowEmptyCollection()][byte[]]$Bytes = @(),
        [Parameter(Mandatory = $true)][byte[]]$Needle,
        [int]$StartIndex = 0
    )

    if ($Needle.Length -eq 0 -or $StartIndex -lt 0 -or $StartIndex -gt $Bytes.Length) {
        return -1
    }

    $lastStart = $Bytes.Length - $Needle.Length
    for ($index = $StartIndex; $index -le $lastStart; $index++) {
        $matches = $true
        for ($needleIndex = 0; $needleIndex -lt $Needle.Length; $needleIndex++) {
            if ($Bytes[$index + $needleIndex] -ne $Needle[$needleIndex]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            return $index
        }
    }

    return -1
}

function Test-ByteSequenceEqual {
    param(
        [AllowEmptyCollection()][byte[]]$Left = @(),
        [AllowEmptyCollection()][byte[]]$Right = @()
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }

    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }

    return $true
}

function Add-Bytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [AllowEmptyCollection()][byte[]]$Bytes = @()
    )

    if ($Bytes.Length -gt 0) {
        $Stream.Write($Bytes, 0, $Bytes.Length)
    }
}

function New-ManagedAgentsBytes {
    param(
        [AllowEmptyCollection()][byte[]]$ExistingBytes = @(),
        [AllowEmptyCollection()][byte[]]$SourceBytes = @()
    )

    $beginBytes = $utf8.GetBytes($beginMarker)
    $endBytes = $utf8.GetBytes($endMarker)
    $newLineBytes = $utf8.GetBytes("`n")
    $beginIndex = Find-ByteSequence -Bytes $ExistingBytes -Needle $beginBytes
    $endIndex = -1
    if ($beginIndex -ge 0) {
        $endIndex = Find-ByteSequence -Bytes $ExistingBytes -Needle $endBytes -StartIndex ($beginIndex + $beginBytes.Length)
        if ($endIndex -lt 0) {
            throw 'Найден неполный управляемый блок AGENTS.md. Восстановите end marker вручную перед установкой.'
        }
    }
    elseif ((Find-ByteSequence -Bytes $ExistingBytes -Needle $endBytes) -ge 0) {
        throw 'Найден end marker без begin marker в AGENTS.md. Восстановите файл вручную перед установкой.'
    }

    $stream = [System.IO.MemoryStream]::new()
    try {
        if ($beginIndex -ge 0) {
            if ($beginIndex -gt 0) {
                $prefix = New-Object byte[] $beginIndex
                [System.Array]::Copy($ExistingBytes, 0, $prefix, 0, $prefix.Length)
                Add-Bytes -Stream $stream -Bytes $prefix
            }
        }
        else {
            Add-Bytes -Stream $stream -Bytes $ExistingBytes
            if ($ExistingBytes.Length -gt 0 -and $ExistingBytes[$ExistingBytes.Length - 1] -ne 10) {
                Add-Bytes -Stream $stream -Bytes $newLineBytes
            }
        }

        Add-Bytes -Stream $stream -Bytes $beginBytes
        Add-Bytes -Stream $stream -Bytes $newLineBytes
        Add-Bytes -Stream $stream -Bytes $SourceBytes
        if ($SourceBytes.Length -eq 0 -or $SourceBytes[$SourceBytes.Length - 1] -ne 10) {
            Add-Bytes -Stream $stream -Bytes $newLineBytes
        }
        Add-Bytes -Stream $stream -Bytes $endBytes

        if ($beginIndex -ge 0) {
            $suffixStart = $endIndex + $endBytes.Length
            if ($suffixStart -lt $ExistingBytes.Length) {
                $suffix = New-Object byte[] ($ExistingBytes.Length - $suffixStart)
                [System.Array]::Copy($ExistingBytes, $suffixStart, $suffix, 0, $suffix.Length)
                Add-Bytes -Stream $stream -Bytes $suffix
            }
        }
        else {
            Add-Bytes -Stream $stream -Bytes $newLineBytes
        }

        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $directory = Split-Path -Parent $Destination
    $temporary = Join-Path $directory ('.codex-development-system.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        if (Test-Path -LiteralPath $Destination) {
            # Резервная копия создаётся вызывающим кодом до замены. В Windows
            # File.Copy с overwrite поддерживает PS 5.1 без зависимости от
            # File.Replace, которая недоступна на части файловых систем.
            [System.IO.File]::Copy($temporary, $Destination, $true)
            Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
        }
        else {
            [System.IO.File]::Move($temporary, $Destination)
        }
    }
    catch {
        throw "Не удалось безопасно записать '$Destination'. Исходный файл не заменён без успешного завершения операции: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-VerifiedSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string]$RequestedVersion
    )

    $versionPath = Get-GovernanceVersionPath -RepositoryRoot $RepositoryPath -Version $RequestedVersion
    $globalPath = Join-Path $versionPath.FullName 'global'
    $agentsPath = Join-Path $globalPath 'agents'
    if (-not (Test-Path -LiteralPath $globalPath -PathType Container) -or -not (Test-Path -LiteralPath $agentsPath -PathType Container)) {
        throw "Опубликованный snapshot версии $RequestedVersion неполон: не найден global/agents."
    }

    $agents = @{}
    foreach ($name in $expectedAgentNames) {
        $path = Join-Path $agentsPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Опубликованный snapshot версии $RequestedVersion неполон: не найден $name."
        }
        $agents[$name] = $path
    }

    $agentsFileNames = @(Get-ChildItem -LiteralPath $agentsPath -File -Filter '*.toml' -ErrorAction Stop | ForEach-Object { $_.Name })
    if ($agentsFileNames.Count -lt $expectedAgentNames.Count) {
        throw "Опубликованный snapshot версии $RequestedVersion неполон: найдено менее девяти TOML-ролей."
    }

    $agentsRulesPath = Join-Path $globalPath 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsRulesPath -PathType Leaf)) {
        throw "Опубликованный snapshot версии $RequestedVersion неполон: не найден global/AGENTS.md."
    }

    return [PSCustomObject]@{
        AgentsRulesPath = $agentsRulesPath
        AgentPaths = $agents
    }
}

$repositoryPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
    throw "Репозиторий не найден: $RepositoryRoot"
}

$snapshot = Get-VerifiedSnapshot -RepositoryPath $repositoryPath -RequestedVersion $Version
$codexHomePath = Assert-SafeCodexHome -Path $CodexHome -RepositoryPath $repositoryPath
if (Test-PathInside -Candidate $codexHomePath -Container (Split-Path -Parent $snapshot.AgentsRulesPath)) {
    throw "Опасная цель CodexHome: нельзя устанавливать внутри исходного snapshot: $CodexHome"
}
$agentsDestinationPath = [System.IO.Path]::GetFullPath((Join-Path $codexHomePath 'agents'))
$agentsRulesDestination = [System.IO.Path]::GetFullPath((Join-Path $codexHomePath 'AGENTS.md'))
Assert-NoReparsePoint -Path $agentsDestinationPath
Assert-NoReparsePoint -Path $agentsRulesDestination

if ((Test-Path -LiteralPath $codexHomePath) -and -not (Test-Path -LiteralPath $codexHomePath -PathType Container)) {
    throw "CodexHome должен быть каталогом: $codexHomePath"
}
if ((Test-Path -LiteralPath $agentsDestinationPath) -and -not (Test-Path -LiteralPath $agentsDestinationPath -PathType Container)) {
    throw "Каталог agents не является каталогом: $agentsDestinationPath"
}
if ((Test-Path -LiteralPath $agentsRulesDestination) -and -not (Test-Path -LiteralPath $agentsRulesDestination -PathType Leaf)) {
    throw "AGENTS.md назначения не является файлом: $agentsRulesDestination"
}

$sourceRulesBytes = [System.IO.File]::ReadAllBytes($snapshot.AgentsRulesPath)
[byte[]]$existingRulesBytes = @()
if (Test-Path -LiteralPath $agentsRulesDestination -PathType Leaf) {
    $existingRulesBytes = [System.IO.File]::ReadAllBytes($agentsRulesDestination)
}
$managedRulesBytes = New-ManagedAgentsBytes -ExistingBytes $existingRulesBytes -SourceBytes $sourceRulesBytes
$plan = [System.Collections.Generic.List[object]]::new()
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture)
if (-not (Test-Path -LiteralPath $codexHomePath)) {
    $plan.Add([PSCustomObject]@{ Kind = 'CreateDirectory'; Target = $codexHomePath; Source = $null; Backup = $null })
}
if (-not (Test-Path -LiteralPath $agentsDestinationPath)) {
    $plan.Add([PSCustomObject]@{ Kind = 'CreateDirectory'; Target = $agentsDestinationPath; Source = $null; Backup = $null })
}
if (-not (Test-ByteSequenceEqual -Left $existingRulesBytes -Right $managedRulesBytes)) {
    $rulesBackup = $null
    if (Test-Path -LiteralPath $agentsRulesDestination) {
        $rulesBackup = $agentsRulesDestination + '.backup-' + $timestamp
        $suffix = 1
        while (Test-Path -LiteralPath $rulesBackup) {
            $rulesBackup = $agentsRulesDestination + '.backup-' + $timestamp + '-' + $suffix
            $suffix++
        }
    }
    $plan.Add([PSCustomObject]@{ Kind = 'WriteManagedRules'; Target = $agentsRulesDestination; Source = $snapshot.AgentsRulesPath; Backup = $rulesBackup; Bytes = $managedRulesBytes })
}

foreach ($name in $expectedAgentNames) {
    $sourcePath = $snapshot.AgentPaths[$name]
    $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $agentsDestinationPath $name))
    Assert-NoReparsePoint -Path $destinationPath
    if ((Test-Path -LiteralPath $destinationPath) -and -not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        throw "Файл роли назначения не является файлом: $destinationPath"
    }

    $sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
    if (-not (Test-Path -LiteralPath $destinationPath)) {
        $plan.Add([PSCustomObject]@{ Kind = 'AddAgent'; Target = $destinationPath; Source = $sourcePath; Backup = $null; Bytes = $sourceBytes })
        continue
    }

    $destinationBytes = [System.IO.File]::ReadAllBytes($destinationPath)
    if (Test-ByteSequenceEqual -Left $sourceBytes -Right $destinationBytes) {
        continue
    }

    $backupPath = $destinationPath + '.backup-' + $timestamp
    $suffix = 1
    while (Test-Path -LiteralPath $backupPath) {
        $backupPath = $destinationPath + '.backup-' + $timestamp + '-' + $suffix
        $suffix++
    }
    $plan.Add([PSCustomObject]@{ Kind = 'ReplaceAgent'; Target = $destinationPath; Source = $sourcePath; Backup = $backupPath; Bytes = $sourceBytes })
}

Write-Host 'План безопасной установки:'
if ($plan.Count -eq 0) {
    Write-Host '  No-op: все управляемые файлы уже соответствуют выбранному snapshot.'
}
else {
    foreach ($operation in $plan) {
        $suffix = if ($null -eq $operation.Backup) { '' } else { "; backup: $($operation.Backup)" }
        Write-Host "  $($operation.Kind): $($operation.Target)$suffix"
    }
}

if (-not $PSCmdlet.ShouldProcess($codexHomePath, "Установить глобальные правила версии $Version")) {
    return
}

try {
    foreach ($operation in $plan | Where-Object { $_.Kind -eq 'CreateDirectory' }) {
        New-Item -ItemType Directory -Path $operation.Target -Force -ErrorAction Stop | Out-Null
    }
    Assert-NoReparsePoint -Path $codexHomePath
    Assert-NoReparsePoint -Path $agentsDestinationPath

    foreach ($operation in $plan | Where-Object { $_.Kind -eq 'WriteManagedRules' }) {
        if ($null -ne $operation.Backup) {
            [System.IO.File]::Copy($operation.Target, $operation.Backup, $false)
        }
        Write-AtomicBytes -Destination $operation.Target -Bytes $operation.Bytes
    }
    foreach ($operation in $plan | Where-Object { $_.Kind -eq 'AddAgent' }) {
        Write-AtomicBytes -Destination $operation.Target -Bytes $operation.Bytes
    }
    foreach ($operation in $plan | Where-Object { $_.Kind -eq 'ReplaceAgent' }) {
        [System.IO.File]::Copy($operation.Target, $operation.Backup, $false)
        Write-AtomicBytes -Destination $operation.Target -Bytes $operation.Bytes
    }
}
catch {
    throw "Глобальная установка остановлена. Созданные резервные копии сохранены; проверьте план и состояние назначения. Причина: $($_.Exception.Message)"
}
