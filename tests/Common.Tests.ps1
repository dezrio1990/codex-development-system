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

    It 'возвращает путь версии только внутри versions' {
        $path = Get-GovernanceVersionPath -RepositoryRoot $repositoryRoot -Version '1.0.0'
        Assert-Equal $path.FullName (Join-Path $repositoryRoot 'versions/1.0.0')
    }

    It 'читает manifest установленного проекта' {
        $project = New-FixtureDirectory 'manifest'
        try {
            $manifestDirectory = Join-Path $project '.codex/governance'
            New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
            '{"schemaVersion":1,"rulesVersion":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $manifestDirectory 'manifest.json') -NoNewline

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

    It 'не заменяет файл без Replace и заменяет его с Replace' {
        $fixture = New-FixtureDirectory 'copy'
        try {
            $source = Join-Path $fixture 'source.txt'
            $destination = Join-Path $fixture 'destination.txt'
            [System.IO.File]::WriteAllText($source, 'source')
            [System.IO.File]::WriteAllText($destination, 'destination')

            Assert-Throws { Copy-GovernanceFile -Source $source -Destination $destination }
            Copy-GovernanceFile -Source $source -Destination $destination -Replace

            Assert-Equal ([System.IO.File]::ReadAllText($destination)) 'source'
        }
        finally {
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
