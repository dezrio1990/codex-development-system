$Root = Split-Path -Parent $PSScriptRoot
$InitializerPath = Join-Path $Root 'current/scripts/Initialize-ProjectRules.ps1'
$CommonModulePath = Join-Path $Root 'current/scripts/Governance.Common.psm1'
$Utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-BytesEqual {
    param([byte[]]$Actual, [byte[]]$Expected)

    if ($Actual.Length -ne $Expected.Length) { throw 'Байтовые массивы имеют разную длину.' }
    for ($index = 0; $index -lt $Actual.Length; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) { throw "Байтовые массивы отличаются в позиции $index." }
    }
}

function Get-TreeFingerprint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName)
    $lines = foreach ($item in $items) {
        $relative = $item.FullName.Substring($Path.TrimEnd([char]92, [char]'/' ).Length).TrimStart([char]92, [char]'/' ).Replace([char]92, [char]'/')
        if ($item.PSIsContainer) { "D $relative" } else { "F $relative $([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($item.FullName)))" }
    }
    return [string]::Join("`n", @($lines))
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)

    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart([char]92, [char]'/' )
        $target = Join-Path $Destination $relative
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($file.FullName))
    }
}

function Write-ReleaseMetadata {
    param([string]$ReleasePath)

    Import-Module -Name $CommonModulePath -Force
    $contentHash = Get-GovernanceContentHash -RootPath $ReleasePath
    $version = [ordered]@{
        version = '1.0.0'
        channel = 'stable'
        gitTag = 'v1.0.0'
        gitCommit = '0123456789abcdef0123456789abcdef01234567'
        contentHash = $contentHash
        releasedAt = '2026-09-14T00:00:00.0000000Z'
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllBytes((Join-Path $ReleasePath 'version.json'), $Utf8.GetBytes($version + "`n"))
    $checksums = @(Get-GovernanceChecksums -RootPath $ReleasePath)
    [System.IO.File]::WriteAllBytes((Join-Path $ReleasePath 'checksums.sha256'), $Utf8.GetBytes(($checksums -join "`n") + "`n"))
}

function New-InitializeFixture {
    $container = Join-Path ([System.IO.Path]::GetTempPath()) ('governance-initialize-' + [guid]::NewGuid().ToString('N'))
    $fixture = Join-Path $container 'repository'
    $release = Join-Path $fixture 'versions/1.0.0'
    New-Item -ItemType Directory -Path $release -Force | Out-Null
    Copy-Tree -Source (Join-Path $Root 'current/templates') -Destination (Join-Path $release 'templates')
    Write-ReleaseMetadata -ReleasePath $release
    $project = Join-Path $container 'project-alpha'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    return [PSCustomObject]@{ Root = $fixture; Release = $release; Project = $project; Container = $container }
}

function Remove-InitializeFixture {
    param($Fixture)
    if ($Fixture -and (Test-Path -LiteralPath $Fixture.Container)) { Remove-Item -LiteralPath $Fixture.Container -Recurse -Force }
}

function Invoke-Initializer {
    param($Fixture, [string[]]$Overlays = @('android', 'dotnet'), [switch]$Apply)
    & $InitializerPath -RepositoryRoot $Fixture.Root -ProjectPath $Fixture.Project -Version '1.0.0' -Overlay $Overlays -Apply:$Apply
}

function Get-ProjectManifest {
    param($Fixture)
    return (Get-Content -LiteralPath (Join-Path $Fixture.Project '.codex/governance/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

Describe 'Инициализация прикладного проекта из закреплённого выпуска' {
    It 'preview не изменяет чистый или конфликтующий проект' {
        $fixture = New-InitializeFixture
        try {
            $conflict = Join-Path $fixture.Project 'AGENTS.md'
            [System.IO.File]::WriteAllBytes($conflict, $Utf8.GetBytes('пользовательские правила'))
            $before = Get-TreeFingerprint $fixture.Project

            Invoke-Initializer -Fixture $fixture | Out-Null

            Assert-Equal (Get-TreeFingerprint $fixture.Project) $before
        }
        finally { Remove-InitializeFixture $fixture }
    }

    It 'применяет base и canonical overlays с отрендеренными токенами и manifest' {
        $fixture = New-InitializeFixture
        try {
            Invoke-Initializer -Fixture $fixture -Overlays @('dotnet', 'android') -Apply | Out-Null
            $manifest = Get-ProjectManifest $fixture
            Assert-Equal $manifest.schemaVersion 1
            Assert-Equal $manifest.rulesSource 'https://github.com/dezrio1990/codex-development-system'
            Assert-Equal $manifest.rulesVersion '1.0.0'
            Assert-Equal $manifest.rulesCommit '0123456789abcdef0123456789abcdef01234567'
            Assert-SequenceEqual @($manifest.overlays) @('android', 'dotnet')
            Assert-Equal $manifest.installedAt $manifest.updatedAt
            if ($manifest.releaseContentHash -notmatch '^[0-9a-f]{64}$' -or $manifest.installedContentHash -notmatch '^[0-9a-f]{64}$') { throw 'Manifest не содержит SHA-256.' }

            foreach ($path in @('AGENTS.md', '.codex/governance/base-rules.md', '.codex/governance/overlays/android.md', '.codex/governance/overlays/dotnet.md', 'docs/status/current.md')) {
                if (-not (Test-Path -LiteralPath (Join-Path $fixture.Project $path) -PathType Leaf)) { throw "Не создан $path." }
            }
            $rootAgents = Get-Content -LiteralPath (Join-Path $fixture.Project 'AGENTS.md') -Raw -Encoding UTF8
            foreach ($required in @('.codex/governance/base-rules.md', '.codex/governance/overlays/android.md', '.codex/governance/overlays/dotnet.md')) {
                if ($rootAgents.IndexOf($required, [System.StringComparison]::Ordinal) -lt 0) { throw "В root AGENTS нет обязательства прочитать $required." }
            }
            foreach ($markdown in Get-ChildItem -LiteralPath $fixture.Project -Recurse -Filter '*.md' -File) {
                if ((Get-Content -LiteralPath $markdown.FullName -Raw -Encoding UTF8) -match '\{\{[^}]+\}\}') { throw "В $($markdown.FullName) остался токен." }
            }

            Import-Module -Name $CommonModulePath -Force
            $payload = Join-Path $fixture.Root 'installed-payload'
            New-Item -ItemType Directory -Path (Join-Path $payload 'overlays') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $fixture.Project '.codex/governance/base-rules.md') -Destination (Join-Path $payload 'base-rules.md')
            Copy-Item -LiteralPath (Join-Path $fixture.Project '.codex/governance/overlays/android.md') -Destination (Join-Path $payload 'overlays/android.md')
            Copy-Item -LiteralPath (Join-Path $fixture.Project '.codex/governance/overlays/dotnet.md') -Destination (Join-Path $payload 'overlays/dotnet.md')
            Assert-Equal (Get-GovernanceContentHash -RootPath $payload) $manifest.installedContentHash
        }
        finally { Remove-InitializeFixture $fixture }
    }

    It 'отклоняет duplicate и неизвестный overlay до записи и canonicalizes порядок' {
        $fixture = New-InitializeFixture
        try {
            $before = Get-TreeFingerprint $fixture.Project
            Assert-Throws { Invoke-Initializer -Fixture $fixture -Overlays @('android', 'android') } 'duplicate|повтор|overlay'
            Assert-Throws { Invoke-Initializer -Fixture $fixture -Overlays @('unknown') } 'overlay|не найден'
            Assert-Equal (Get-TreeFingerprint $fixture.Project) $before
        }
        finally { Remove-InitializeFixture $fixture }
    }

    It 'same pin является no-op после изменения проектного документа' {
        $fixture = New-InitializeFixture
        try {
            Invoke-Initializer -Fixture $fixture -Apply | Out-Null
            $document = Join-Path $fixture.Project 'docs/status/current.md'
            [System.IO.File]::WriteAllBytes($document, $Utf8.GetBytes('собственная правка проекта'))
            $manifestPath = Join-Path $fixture.Project '.codex/governance/manifest.json'
            $manifestBefore = [System.IO.File]::ReadAllBytes($manifestPath)

            Invoke-Initializer -Fixture $fixture -Apply | Out-Null

            Assert-Equal (Get-Content -LiteralPath $document -Raw -Encoding UTF8) 'собственная правка проекта'
            Assert-BytesEqual ([System.IO.File]::ReadAllBytes($manifestPath)) $manifestBefore
            Assert-Equal (@(Get-ChildItem -LiteralPath $fixture.Project -Recurse -Filter '*.backup-*' -File).Count) 0
        }
        finally { Remove-InitializeFixture $fixture }
    }

    It 'routing к Sync при ином, malformed или drifted manifest не пишет проект' {
        foreach ($kind in @('different', 'malformed', 'invalid-field', 'drifted')) {
            $fixture = New-InitializeFixture
            try {
                Invoke-Initializer -Fixture $fixture -Apply | Out-Null
                $manifestPath = Join-Path $fixture.Project '.codex/governance/manifest.json'
                if ($kind -eq 'different') {
                    $manifest = Get-ProjectManifest $fixture
                    $manifest.rulesVersion = '2.0.0'
                    [System.IO.File]::WriteAllBytes($manifestPath, $Utf8.GetBytes(($manifest | ConvertTo-Json) + "`n"))
                }
                elseif ($kind -eq 'malformed') { [System.IO.File]::WriteAllBytes($manifestPath, $Utf8.GetBytes('{broken')) }
                elseif ($kind -eq 'invalid-field') {
                    $manifest = Get-ProjectManifest $fixture
                    $manifest.installedAt = 'не-дата'
                    [System.IO.File]::WriteAllBytes($manifestPath, $Utf8.GetBytes(($manifest | ConvertTo-Json) + "`n"))
                }
                else { [System.IO.File]::WriteAllBytes((Join-Path $fixture.Project '.codex/governance/base-rules.md'), $Utf8.GetBytes('дрейф')) }
                $before = Get-TreeFingerprint $fixture.Project

                Assert-Throws { Invoke-Initializer -Fixture $fixture -Apply } 'Sync-ProjectRules'

                Assert-Equal (Get-TreeFingerprint $fixture.Project) $before
            }
            finally { Remove-InitializeFixture $fixture }
        }
    }

    It 'создаёт backups конфликтов и сохраняет неизвестные файлы' {
        $fixture = New-InitializeFixture
        try {
            $agents = Join-Path $fixture.Project 'AGENTS.md'
            $original = $Utf8.GetBytes('старый AGENTS')
            [System.IO.File]::WriteAllBytes($agents, $original)
            $unknown = Join-Path $fixture.Project '.codex/governance/custom.txt'
            New-Item -ItemType Directory -Path (Split-Path -Parent $unknown) -Force | Out-Null
            [System.IO.File]::WriteAllBytes($unknown, $Utf8.GetBytes('неизвестный файл'))

            Invoke-Initializer -Fixture $fixture -Apply | Out-Null

            $backups = @(Get-ChildItem -LiteralPath $fixture.Project -Recurse -Filter 'AGENTS.md.backup-*' -File)
            Assert-Equal $backups.Count 1
            Assert-BytesEqual ([System.IO.File]::ReadAllBytes($backups[0].FullName)) $original
            Assert-Equal (Get-Content -LiteralPath $unknown -Raw -Encoding UTF8) 'неизвестный файл'
        }
        finally { Remove-InitializeFixture $fixture }
    }

    It 'отклоняет испорченный выпуск и опасный ProjectPath до записи' {
        foreach ($mutation in @('version', 'checksums', 'missing-base', 'unsafe-checksum')) {
            $fixture = New-InitializeFixture
            try {
                if ($mutation -eq 'version') {
                    $versionPath = Join-Path $fixture.Release 'version.json'
                    $version = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $version.contentHash = ('0' * 64)
                    [System.IO.File]::WriteAllBytes($versionPath, $Utf8.GetBytes(($version | ConvertTo-Json) + "`n"))
                }
                elseif ($mutation -eq 'checksums') { Add-Content -LiteralPath (Join-Path $fixture.Release 'checksums.sha256') -Value 'bad  templates/base/AGENTS.md' -Encoding UTF8 }
                elseif ($mutation -eq 'missing-base') { Remove-Item -LiteralPath (Join-Path $fixture.Release 'templates/base/AGENTS.md') -Force }
                else { [System.IO.File]::WriteAllBytes((Join-Path $fixture.Release 'checksums.sha256'), $Utf8.GetBytes(('0' * 64) + '  ../unsafe.md' + "`n")) }
                $before = Get-TreeFingerprint $fixture.Project

                Assert-Throws { Invoke-Initializer -Fixture $fixture -Apply } 'hash|checksum|base|снимок|unsafe|небезопас'
                Assert-Equal (Get-TreeFingerprint $fixture.Project) $before
            }
            finally { Remove-InitializeFixture $fixture }
        }

        $fixture = New-InitializeFixture
        try {
            $before = Get-TreeFingerprint $fixture.Root
            Assert-Throws { & $InitializerPath -RepositoryRoot $fixture.Root -ProjectPath $fixture.Root -Version '1.0.0' -Overlay @('android') -Apply } 'репозитори|опасн'
            Assert-Equal (Get-TreeFingerprint $fixture.Root) $before
        }
        finally { Remove-InitializeFixture $fixture }
    }
}
