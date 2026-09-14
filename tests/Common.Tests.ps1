$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$modulePath = Join-Path $repositoryRoot 'current/scripts/Governance.Common.psm1'

if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
}

function New-FixtureDirectory {
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("governance-common-$Name-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Write-FixtureFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $path = Join-Path $Root $RelativePath
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
}

Describe 'Governance.Common' {
    It 'строит одинаковый SHA-256 независимо от порядка обхода файлов' {
        $fixtureA = New-FixtureDirectory 'hash-a'
        $fixtureB = New-FixtureDirectory 'hash-b'
        try {
            Write-FixtureFile $fixtureA 'zeta.txt' 'zeta'
            Write-FixtureFile $fixtureA 'nested/alpha.txt' 'alpha'
            Write-FixtureFile $fixtureB 'nested/alpha.txt' 'alpha'
            Write-FixtureFile $fixtureB 'zeta.txt' 'zeta'

            $first = Get-GovernanceContentHash -RootPath $fixtureA
            $second = Get-GovernanceContentHash -RootPath $fixtureB

            Assert-Equal $first $second
        }
        finally {
            Remove-Item -LiteralPath $fixtureA, $fixtureB -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'отклоняет путь версии вне versions' {
        Assert-Throws { Get-GovernanceVersionPath -RepositoryRoot $repositoryRoot -Version '..\outside' }
    }

    It 'отклоняет SemVer с ведущими нулями' {
        foreach ($invalidVersion in @(
            '01.0.0',
            '1.01.0',
            '1.0.00',
            '1.0.0-01',
            '1.0.0-alpha.01',
            '1.2٢.3',
            ('1.2.3' + [char]10),
            ('1.2.3' + [char]13),
            ('1.2.3' + [char]13 + [char]10)
        )) {
            Assert-Throws { Get-GovernanceVersionPath -RepositoryRoot $repositoryRoot -Version $invalidVersion }
        }
    }

    It 'принимает корректные SemVer prerelease и build metadata' {
        foreach ($validVersion in @('0.0.0', '1.2.3-rc.1', '1.2.3-alpha.1+build.5', '10.20.30-0A-.-beta+exp.sha.5114f85')) {
            $path = Get-GovernanceVersionPath -RepositoryRoot $repositoryRoot -Version $validVersion
            Assert-Equal $path.Name $validVersion
        }
    }

    It 'схемы используют строгий SemVer 2.0' {
        $versionSchema = Get-Content -LiteralPath (Join-Path $repositoryRoot 'schemas/version.schema.json') -Raw | ConvertFrom-Json
        $manifestSchema = Get-Content -LiteralPath (Join-Path $repositoryRoot 'schemas/project-manifest.schema.json') -Raw | ConvertFrom-Json
        $supportSchema = Get-Content -LiteralPath (Join-Path $repositoryRoot 'schemas/support.schema.json') -Raw | ConvertFrom-Json
        $patterns = @(
            $versionSchema.properties.version.pattern,
            $manifestSchema.properties.rulesVersion.pattern,
            $supportSchema.properties.versions.propertyNames.pattern
        )

        foreach ($pattern in $patterns) {
            foreach ($invalidVersion in @(
                '01.0.0',
                '1.01.0',
                '1.0.00',
                '1.0.0-01',
                '1.0.0-alpha.01',
                '1.2٢.3',
                ('1.2.3' + [char]10),
                ('1.2.3' + [char]13),
                ('1.2.3' + [char]13 + [char]10)
            )) {
                if ($invalidVersion -match $pattern) {
                    throw "Схема принимает недопустимую версию '$invalidVersion'."
                }
            }
            foreach ($validVersion in @('0.0.0', '1.2.3-rc.1', '1.2.3-alpha.1+build.5')) {
                if ($validVersion -notmatch $pattern) {
                    throw "Схема отклоняет допустимую версию '$validVersion'."
                }
            }
        }

        $gitTagPattern = $versionSchema.properties.gitTag.pattern
        foreach ($invalidTag in @(
            'v01.0.0',
            'v1.01.0',
            'v1.0.00',
            'v1.0.0-01',
            'v1.2٢.3',
            ('v1.2.3' + [char]10),
            ('v1.2.3' + [char]13),
            ('v1.2.3' + [char]13 + [char]10)
        )) {
            if ($invalidTag -match $gitTagPattern) {
                throw "Схема принимает недопустимый Git-тег '$invalidTag'."
            }
        }
        if ('v1.2.3-alpha.1+build.5' -notmatch $gitTagPattern) {
            throw 'Схема отклоняет допустимый Git-тег.'
        }
    }

    It 'возвращает путь версии только внутри versions' {
        $path = Get-GovernanceVersionPath -RepositoryRoot $repositoryRoot -Version '1.0.0'
        Assert-Equal $path.FullName (Join-Path $repositoryRoot 'versions/1.0.0')
    }

    It 'читает manifest установленного проекта' {
        $project = New-FixtureDirectory 'manifest'
        try {
            $manifestDirectory = Join-Path $project '.codex/governance'
            New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
            $manifestPath = Join-Path $manifestDirectory 'manifest.json'
            $manifestJson = '{"schemaVersion":1,"rulesVersion":"1.0.0"}'
            $manifestEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
            [System.IO.File]::WriteAllText($manifestPath, $manifestJson, $manifestEncoding)

            $manifest = Get-GovernanceManifest -ProjectPath $project

            Assert-Equal $manifest.rulesVersion '1.0.0'
        }
        finally {
            Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'создаёт воспроизводимый список checksums без служебных файлов' {
        $fixture = New-FixtureDirectory 'checksums'
        try {
            Write-FixtureFile $fixture 'zeta.txt' 'zeta'
            Write-FixtureFile $fixture 'nested/alpha.txt' 'alpha'
            Write-FixtureFile $fixture 'version.json' '{}'
            Write-FixtureFile $fixture 'checksums.sha256' 'ignored'

            $checksums = @(Get-GovernanceChecksums -RootPath $fixture)

            Assert-SequenceEqual $checksums @(
                '8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8  nested/alpha.txt',
                '5cc10d9143b2cff082cf5fb373073b13d02d12c9a4d24a97d822d701404fb421  zeta.txt'
            )
        }
        finally {
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'сортирует пути checksums через ordinal-ignore-case' {
        $fixture = New-FixtureDirectory 'ordinal-sort'
        try {
            Write-FixtureFile $fixture 'zeta.txt' 'zeta'
            Write-FixtureFile $fixture 'äther.txt' 'umlaut'

            $paths = @(Get-GovernanceChecksums -RootPath $fixture | ForEach-Object {
                $_ -replace '^[0-9a-f]{64}  ', ''
            })

            Assert-SequenceEqual $paths @('zeta.txt', 'äther.txt')
        }
        finally {
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'отклоняет совпадение нормализованных относительных путей' {
        $module = Get-Module Governance.Common
        Assert-Throws -MessagePattern 'Нормализованные относительные пути конфликтуют' {
            & $module { Assert-GovernanceUniqueRelativePaths -RelativePaths @('A.txt', 'a.txt') }
        }
    }

    It 'отклоняет case-colliding файлы, когда файловая система их поддерживает' {
        $fixture = New-FixtureDirectory 'case-collision'
        try {
            Write-FixtureFile $fixture 'A.txt' 'upper'
            Write-FixtureFile $fixture 'a.txt' 'lower'
            $files = @(Get-ChildItem -LiteralPath $fixture -File)

            if ($files.Count -eq 2) {
                Assert-Throws -MessagePattern 'Нормализованные относительные пути конфликтуют' {
                    Get-GovernanceChecksums -RootPath $fixture
                }
            }
            else {
                $module = Get-Module Governance.Common
                Assert-Throws -MessagePattern 'Нормализованные относительные пути конфликтуют' {
                    & $module { Assert-GovernanceUniqueRelativePaths -RelativePaths @('A.txt', 'a.txt') }
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'не заменяет файл без Replace и заменяет его с Replace' {
        $fixture = New-FixtureDirectory 'copy'
        try {
            $source = Join-Path $fixture 'source.txt'
            $destination = Join-Path $fixture 'destination.txt'
            [System.IO.File]::WriteAllText($source, 'source', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($destination, 'destination', [System.Text.UTF8Encoding]::new($false))

            Assert-Throws { Copy-GovernanceFile -Source $source -Destination $destination }
            Copy-GovernanceFile -Source $source -Destination $destination -Replace

            Assert-Equal ([System.IO.File]::ReadAllText($destination)) 'source'
        }
        finally {
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
