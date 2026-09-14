$Root = Split-Path -Parent $PSScriptRoot
$InstallerPath = Join-Path $Root 'current/scripts/Install-GlobalRules.ps1'
$PayloadPath = Join-Path $Root 'current/global'
$ExpectedAgentNames = @(
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

function New-InstallFixture {
    $fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("governance-install-" + [guid]::NewGuid().ToString('N'))
    $globalPath = Join-Path $fixture 'versions/1.0.0/global'
    $agentsPath = Join-Path $globalPath 'agents'
    New-Item -ItemType Directory -Path $agentsPath -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PayloadPath 'AGENTS.md') -Destination (Join-Path $globalPath 'AGENTS.md') -Force
    foreach ($name in $ExpectedAgentNames) {
        Copy-Item -LiteralPath (Join-Path $PayloadPath "agents/$name") -Destination (Join-Path $agentsPath $name) -Force
    }

    return $fixture
}

function Remove-InstallFixture {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        [System.IO.Directory]::Delete($Path, $true)
    }
}

function Invoke-GlobalInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [switch]$WhatIf
    )

    if ($WhatIf) {
        & $InstallerPath -RepositoryRoot $RepositoryRoot -Version '1.0.0' -CodexHome $CodexHome -WhatIf
        return
    }

    & $InstallerPath -RepositoryRoot $RepositoryRoot -Version '1.0.0' -CodexHome $CodexHome
}

function Assert-BytesEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][byte[]]$Expected
    )

    if ($Actual.Length -ne $Expected.Length) {
        throw "Размеры байтовых последовательностей отличаются: $($Actual.Length) и $($Expected.Length)."
    }

    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) {
            throw "Байтовые последовательности отличаются на позиции $index."
        }
    }
}

function Assert-BytesStartWith {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][byte[]]$ExpectedPrefix
    )

    if ($Actual.Length -lt $ExpectedPrefix.Length) {
        throw 'Файл короче ожидаемого пользовательского префикса.'
    }

    for ($index = 0; $index -lt $ExpectedPrefix.Length; $index++) {
        if ($Actual[$index] -ne $ExpectedPrefix[$index]) {
            throw "Пользовательский префикс изменён на позиции $index."
        }
    }
}

Describe 'Безопасная глобальная установка' {
    It 'устанавливает управляемый блок и ровно девять ролей без изменения пользовательского префикса' {
        $fixture = New-InstallFixture
        try {
            $codexHome = Join-Path $fixture 'sandbox/codex'
            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
            $prefix = [System.Text.UTF8Encoding]::new($false).GetBytes("Пользовательский пролог`n")
            [System.IO.File]::WriteAllBytes((Join-Path $codexHome 'AGENTS.md'), $prefix)

            Invoke-GlobalInstaller -RepositoryRoot $fixture -CodexHome $codexHome | Out-Null

            $agents = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'agents') -Filter '*.toml' -File | ForEach-Object { $_.Name } | Sort-Object)
            Assert-SequenceEqual $agents @($ExpectedAgentNames | Sort-Object)
            $agentsContent = [System.IO.File]::ReadAllBytes((Join-Path $codexHome 'AGENTS.md'))
            Assert-BytesStartWith $agentsContent $prefix
            $text = [System.Text.UTF8Encoding]::new($false).GetString($agentsContent)
            Assert-Equal ([regex]::Matches($text, '<!-- codex-development-system:begin -->').Count) 1
            Assert-Equal ([regex]::Matches($text, '<!-- codex-development-system:end -->').Count) 1
        }
        finally {
            Remove-InstallFixture $fixture
        }
    }

    It 'повторная установка не дублирует блок и не создаёт резервных копий' {
        $fixture = New-InstallFixture
        try {
            $codexHome = Join-Path $fixture 'sandbox/codex'
            Invoke-GlobalInstaller -RepositoryRoot $fixture -CodexHome $codexHome | Out-Null
            $before = [System.IO.File]::ReadAllBytes((Join-Path $codexHome 'AGENTS.md'))

            Invoke-GlobalInstaller -RepositoryRoot $fixture -CodexHome $codexHome | Out-Null

            Assert-BytesEqual ([System.IO.File]::ReadAllBytes((Join-Path $codexHome 'AGENTS.md'))) $before
            $text = Get-Content -LiteralPath (Join-Path $codexHome 'AGENTS.md') -Raw -Encoding UTF8
            Assert-Equal ([regex]::Matches($text, '<!-- codex-development-system:begin -->').Count) 1
            Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $codexHome 'agents') -Filter '*.backup-*' -File).Count) 0
        }
        finally {
            Remove-InstallFixture $fixture
        }
    }

    It 'сохраняет конфликтующую роль в уникальной резервной копии перед заменой' {
        $fixture = New-InstallFixture
        try {
            $codexHome = Join-Path $fixture 'sandbox/codex'
            $agentsPath = Join-Path $codexHome 'agents'
            New-Item -ItemType Directory -Path $agentsPath -Force | Out-Null
            $destination = Join-Path $agentsPath 'android_developer.toml'
            $original = [System.Text.UTF8Encoding]::new($false).GetBytes('user-owned conflicting role')
            [System.IO.File]::WriteAllBytes($destination, $original)

            Invoke-GlobalInstaller -RepositoryRoot $fixture -CodexHome $codexHome | Out-Null

            $backups = @(Get-ChildItem -LiteralPath $agentsPath -Filter 'android_developer.toml.backup-*' -File)
            Assert-Equal $backups.Count 1
            Assert-BytesEqual ([System.IO.File]::ReadAllBytes($backups[0].FullName)) $original
            Assert-BytesEqual ([System.IO.File]::ReadAllBytes($destination)) ([System.IO.File]::ReadAllBytes((Join-Path $fixture 'versions/1.0.0/global/agents/android_developer.toml')))
        }
        finally {
            Remove-InstallFixture $fixture
        }
    }

    It 'сохраняет неизвестные файлы и обновляет только управляемый блок из snapshot' {
        $fixture = New-InstallFixture
        try {
            $codexHome = Join-Path $fixture 'sandbox/codex'
            $agentsPath = Join-Path $codexHome 'agents'
            New-Item -ItemType Directory -Path $agentsPath -Force | Out-Null
            $unknownPath = Join-Path $agentsPath 'custom.toml'
            $unknown = [System.Text.UTF8Encoding]::new($false).GetBytes('custom = true')
            [System.IO.File]::WriteAllBytes($unknownPath, $unknown)

            Invoke-GlobalInstaller -RepositoryRoot $fixture -CodexHome $codexHome | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $fixture 'versions/1.0.0/global/AGENTS.md'), [System.Text.UTF8Encoding]::new($false).GetBytes('# Новая редакция'))
            Invoke-GlobalInstaller -RepositoryRoot $fixture -CodexHome $codexHome | Out-Null

            Assert-BytesEqual ([System.IO.File]::ReadAllBytes($unknownPath)) $unknown
            $text = Get-Content -LiteralPath (Join-Path $codexHome 'AGENTS.md') -Raw -Encoding UTF8
            if ($text.IndexOf('# Новая редакция', [System.StringComparison]::Ordinal) -lt 0) {
                throw 'Управляемый блок не обновлён из опубликованного snapshot.'
            }
        }
        finally {
            Remove-InstallFixture $fixture
        }
    }

    It 'WhatIf не создаёт отсутствующую цель и не меняет диск' {
        $fixture = New-InstallFixture
        try {
            $codexHome = Join-Path $fixture 'never-created/codex'

            Invoke-GlobalInstaller -RepositoryRoot $fixture -CodexHome $codexHome -WhatIf | Out-Null

            Assert-Equal (Test-Path -LiteralPath $codexHome) $false
            Assert-Equal (Test-Path -LiteralPath (Join-Path $fixture 'never-created')) $false
        }
        finally {
            Remove-InstallFixture $fixture
        }
    }

    It 'отклоняет невалидную версию, неполный snapshot и опасные цели до записей' {
        $fixture = New-InstallFixture
        try {
            $safeHome = Join-Path $fixture 'safe/codex'
            Assert-Throws {
                & $InstallerPath -RepositoryRoot $fixture -Version '01.0.0' -CodexHome $safeHome
            } 'SemVer'
            Assert-Equal (Test-Path -LiteralPath $safeHome) $false

            Assert-Throws {
                & $InstallerPath -RepositoryRoot $fixture -Version '1.0.0' -CodexHome $fixture
            } 'репозитори|опасн'
            Assert-Throws {
                & $InstallerPath -RepositoryRoot $fixture -Version '1.0.0' -CodexHome ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile))
            } 'домашн|опасн'

            [System.IO.File]::Delete((Join-Path $fixture 'versions/1.0.0/global/agents/ios_developer.toml'))
            Assert-Throws {
                & $InstallerPath -RepositoryRoot $fixture -Version '1.0.0' -CodexHome $safeHome
            } 'snapshot|снимок|полон'
            Assert-Equal (Test-Path -LiteralPath $safeHome) $false
        }
        finally {
            Remove-InstallFixture $fixture
        }
    }
}
