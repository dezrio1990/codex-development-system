$Root = Split-Path -Parent $PSScriptRoot
$ValidatorPath = Join-Path $Root 'current/scripts/Test-ProjectRules.ps1'
$InitializerPath = Join-Path $Root 'current/scripts/Initialize-ProjectRules.ps1'
$CommonModulePath = Join-Path $Root 'current/scripts/Governance.Common.psm1'
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$ShellPath = (Get-Process -Id $PID).Path

function Copy-ValidationTree {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Write-ValidationReleaseMetadata {
    param([string]$Release)
    Import-Module -Name $CommonModulePath -Force
    $metadata = [ordered]@{
        version = '1.0.0'; channel = 'stable'; gitTag = 'v1.0.0'
        gitCommit = '0123456789abcdef0123456789abcdef01234567'
        contentHash = Get-GovernanceContentHash -RootPath $Release
        releasedAt = '2026-09-14T00:00:00.0000000Z'
    } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllBytes((Join-Path $Release 'version.json'), $Utf8.GetBytes($metadata + "`n"))
    $checksums = @(Get-GovernanceChecksums -RootPath $Release)
    [IO.File]::WriteAllBytes((Join-Path $Release 'checksums.sha256'), $Utf8.GetBytes(($checksums -join "`n") + "`n"))
}

function New-ValidationFixture {
    $container = Join-Path ([IO.Path]::GetTempPath()) ('governance-validation-' + [guid]::NewGuid().ToString('N'))
    $repository = Join-Path $container 'repository'
    $release = Join-Path $repository 'versions/1.0.0'
    Copy-ValidationTree -Source (Join-Path $Root 'current/templates') -Destination (Join-Path $release 'templates')
    Write-ValidationReleaseMetadata -Release $release
    $project = Join-Path $container 'project'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    & $InitializerPath -RepositoryRoot $repository -ProjectPath $project -Version '1.0.0' -Overlay @('android') -Apply | Out-Null
    return [PSCustomObject]@{ Container = $container; Repository = $repository; Release = $release; Project = $project }
}

function Remove-ValidationFixture {
    param($Fixture)
    if ($null -ne $Fixture -and (Test-Path -LiteralPath $Fixture.Container)) { [IO.Directory]::Delete($Fixture.Container, $true) }
}

function Get-ValidationTreeFingerprint {
    param([string]$Path)
    $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($Path.TrimEnd([char]92, [char]'/').Length).TrimStart([char]92, [char]'/').Replace([char]92, [char]'/')
        if ($item.PSIsContainer) { "D $relative" } else { "F $relative $([Convert]::ToBase64String([IO.File]::ReadAllBytes($item.FullName)))" }
    }
    return [string]::Join("`n", @($lines))
}

function Invoke-Validator {
    param($Fixture, [switch]$Human)
    $arguments = @('-NoProfile', '-File', $ValidatorPath, '-ProjectPath', $Fixture.Project, '-RepositoryRoot', $Fixture.Repository)
    if (-not $Human) { $arguments += '-Json' }
    $output = @(& $ShellPath @arguments 2>&1 | ForEach-Object { [string]$_ })
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = [string]::Join("`n", $output) }
}

function Get-ValidationJson {
    param($Response)
    if ([string]::IsNullOrWhiteSpace($Response.Output)) { throw 'Валидатор не вывел JSON.' }
    try { return $Response.Output | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "stdout валидатора не является единственным JSON: $($Response.Output)" }
}

function Assert-ValidationShape {
    param($Json)
    $properties = @($Json.PSObject.Properties.Name | Sort-Object)
    Assert-SequenceEqual $properties @('errors', 'isValid', 'warnings')
    if ($Json.isValid -isnot [bool]) { throw 'isValid должен быть boolean.' }
    foreach ($diagnostic in @($Json.errors) + @($Json.warnings)) {
        Assert-SequenceEqual @($diagnostic.PSObject.Properties.Name | Sort-Object) @('code', 'message', 'path')
        foreach ($name in @('code', 'path', 'message')) { if ($diagnostic.$name -isnot [string]) { throw "$name должен быть string." } }
    }
}

function Assert-ValidationCode {
    param($Json, [string]$Code, [ValidateSet('errors', 'warnings')][string]$Severity)
    if (@($Json.$Severity | Where-Object { $_.code -ceq $Code }).Count -ne 1) { throw "Не найдена диагностика $Code в $Severity." }
}

function Set-ManifestText {
    param($Fixture, [scriptblock]$Mutation)
    $path = Join-Path $Fixture.Project '.codex/governance/manifest.json'
    $manifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Mutation $manifest
    [IO.File]::WriteAllBytes($path, $Utf8.GetBytes(($manifest | ConvertTo-Json -Depth 5) + "`n"))
}

function Set-DocumentFrontMatter {
    param([string]$Path, [string]$FrontMatter)
    $body = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) -replace '(?s)\A---\r?\n.*?\r?\n---\r?\n', ''
    [IO.File]::WriteAllBytes($Path, $Utf8.GetBytes("---`n$FrontMatter`n---`n$body"))
}

Describe 'Проверка закреплённого governance-состояния' {
    It 'возвращает строгое JSON-состояние valid fixture и warning отсутствующего активного плана без записи' {
        $fixture = New-ValidationFixture
        try {
            $before = Get-ValidationTreeFingerprint $fixture.Container
            $response = Invoke-Validator $fixture
            $json = Get-ValidationJson $response
            Assert-Equal $response.ExitCode 0
            Assert-ValidationShape $json
            Assert-Equal $json.isValid $true
            Assert-Equal @($json.errors).Count 0
            Assert-ValidationCode $json 'ACTIVE_PLAN_MISSING' 'warnings'
            Assert-Equal (Get-ValidationTreeFingerprint $fixture.Container) $before
        }
        finally { Remove-ValidationFixture $fixture }
    }

    It 'возвращает каждый обязательный error code с exit 1 и не исправляет состояние' {
        $cases = @(
            @{ Code = 'MANIFEST_MISSING'; Mutate = { param($f) Remove-Item -LiteralPath (Join-Path $f.Project '.codex/governance/manifest.json') -Force } },
            @{ Code = 'VERSION_NOT_FOUND'; Mutate = { param($f) Set-ManifestText $f { param($m) $m.rulesVersion = '2.0.0' } } },
            @{ Code = 'RELEASE_HASH_MISMATCH'; Mutate = { param($f) Add-Content -LiteralPath (Join-Path $f.Release 'templates/base/AGENTS.md') -Value 'изменение' -Encoding UTF8 } },
            @{ Code = 'INSTALLED_HASH_MISMATCH'; Mutate = { param($f) Add-Content -LiteralPath (Join-Path $f.Project '.codex/governance/base-rules.md') -Value 'изменение' -Encoding UTF8 } },
            @{ Code = 'STATUS_INVALID'; Mutate = { param($f) Set-DocumentFrontMatter (Join-Path $f.Project 'docs/status/current.md') "status: Invalid`nrelated: AGENTS.md" } },
            @{ Code = 'APPROVED_PLACEHOLDER'; Mutate = { param($f) Set-DocumentFrontMatter (Join-Path $f.Project 'docs/status/current.md') "status: Approved`nrelated: AGENTS.md"; Add-Content -LiteralPath (Join-Path $f.Project 'docs/status/current.md') -Value 'TODO: заполнить' -Encoding UTF8 } },
            @{ Code = 'RUSSIAN_EXPLANATION_MISSING'; Mutate = { param($f) [IO.File]::WriteAllBytes((Join-Path $f.Project 'docs/english.md'), $Utf8.GetBytes("---`nstatus: Draft`nrelated: docs/status/current.md`n---`n# English document`nOnly English text.`n")) } },
            @{ Code = 'BROKEN_REQUIRED_LINK'; Mutate = { param($f) Set-DocumentFrontMatter (Join-Path $f.Project 'docs/status/current.md') "status: Draft`nrelated: docs/missing.md" } }
        )
        foreach ($case in $cases) {
            $fixture = New-ValidationFixture
            try {
                & $case.Mutate $fixture
                $before = Get-ValidationTreeFingerprint $fixture.Container
                $response = Invoke-Validator $fixture
                $json = Get-ValidationJson $response
                Assert-Equal $response.ExitCode 1
                Assert-Equal $json.isValid $false
                Assert-ValidationCode $json $case.Code 'errors'
                Assert-Equal (Get-ValidationTreeFingerprint $fixture.Container) $before
            }
            finally { Remove-ValidationFixture $fixture }
        }
    }

    It 'возвращает AGENTS_TOO_LARGE как warning без ошибки' {
        $fixture = New-ValidationFixture
        try {
            [IO.File]::AppendAllText((Join-Path $fixture.Project 'AGENTS.md'), (('строка' + "`n") * 501), $Utf8)
            $response = Invoke-Validator $fixture
            $json = Get-ValidationJson $response
            Assert-Equal $response.ExitCode 0
            Assert-ValidationCode $json 'AGENTS_TOO_LARGE' 'warnings'
        }
        finally { Remove-ValidationFixture $fixture }
    }

    It 'отклоняет строгие типы и raw dates manifest отдельной MANIFEST_INVALID диагностикой' {
        foreach ($text in @(
            '{"schemaVersion":"1","rulesSource":"https://github.com/dezrio1990/codex-development-system","rulesVersion":"1.0.0","rulesCommit":"0123456789abcdef0123456789abcdef01234567","releaseContentHash":"0000000000000000000000000000000000000000000000000000000000000000","installedContentHash":"0000000000000000000000000000000000000000000000000000000000000000","overlays":"android","installedAt":"2026-09-14","updatedAt":"2026-09-14"}',
            '{"schemaVersion":1,"rulesSource":"https://github.com/dezrio1990/codex-development-system","rulesVersion":"1.0.0","rulesCommit":"0123456789abcdef0123456789abcdef01234567","releaseContentHash":"0000000000000000000000000000000000000000000000000000000000000000","installedContentHash":"0000000000000000000000000000000000000000000000000000000000000000","overlays":["android"],"installedAt":"2026-09-14T00:00:00+99:99","updatedAt":"2026-09-14T00:00:00.12345678Z"}'
        )) {
            $fixture = New-ValidationFixture
            try {
                [IO.File]::WriteAllBytes((Join-Path $fixture.Project '.codex/governance/manifest.json'), $Utf8.GetBytes($text))
                $json = Get-ValidationJson (Invoke-Validator $fixture)
                Assert-ValidationCode $json 'MANIFEST_INVALID' 'errors'
            }
            finally { Remove-ValidationFixture $fixture }
        }
    }

    It 'отклоняет missing, extra и unsafe vendored overlays как INSTALLED_HASH_MISMATCH' {
        $mutations = @(
            { param($f) Remove-Item -LiteralPath (Join-Path $f.Project '.codex/governance/overlays/android.md') -Force },
            { param($f) [IO.File]::WriteAllBytes((Join-Path $f.Project '.codex/governance/overlays/extra.md'), $Utf8.GetBytes('лишнее')) },
            { param($f) [IO.File]::WriteAllBytes((Join-Path $f.Project '.codex/governance/overlays/bad!.md'), $Utf8.GetBytes('unsafe')) }
        )
        foreach ($mutation in $mutations) {
            $fixture = New-ValidationFixture
            try {
                & $mutation $fixture
                Assert-ValidationCode (Get-ValidationJson (Invoke-Validator $fixture)) 'INSTALLED_HASH_MISMATCH' 'errors'
            }
            finally { Remove-ValidationFixture $fixture }
        }
    }

    It 'отклоняет malformed front matter, invalid Russian explanation и unsafe required link' {
        $mutations = @(
            @{ Codes = @('STATUS_INVALID'); Mutate = { param($f) [IO.File]::WriteAllBytes((Join-Path $f.Project 'docs/status/current.md'), $Utf8.GetBytes("---`nstatus: Draft`n# без закрытия`n")) } },
            @{ Codes = @('BROKEN_REQUIRED_LINK', 'RUSSIAN_EXPLANATION_MISSING'); Mutate = { param($f) [IO.File]::WriteAllBytes((Join-Path $f.Project 'docs/english.md'), $Utf8.GetBytes("---`nstatus: Draft`nrussian_explanation: docs/no-russian.md`n---`n# English`nOnly English.`n")) } },
            @{ Codes = @('BROKEN_REQUIRED_LINK'); Mutate = { param($f) Set-DocumentFrontMatter (Join-Path $f.Project 'docs/status/current.md') "status: Draft`nrelated: ../outside.md" } }
        )
        foreach ($mutation in $mutations) {
            $fixture = New-ValidationFixture
            try {
                & $mutation.Mutate $fixture
                $json = Get-ValidationJson (Invoke-Validator $fixture)
                foreach ($code in $mutation.Codes) { Assert-ValidationCode $json $code 'errors' }
            }
            finally { Remove-ValidationFixture $fixture }
        }
    }

    It 'сохраняет parseable чистый JSON и русские пути при нескольких diagnostics, а human mode не заявляет успех' {
        $fixture = New-ValidationFixture
        try {
            Remove-Item -LiteralPath (Join-Path $fixture.Project '.codex/governance/manifest.json') -Force
            [IO.File]::WriteAllBytes((Join-Path $fixture.Project 'docs/проверка.md'), $Utf8.GetBytes("---`nstatus: Bad`n---`n# English`n"))
            $response = Invoke-Validator $fixture
            if ($response.Output.Trim() -notmatch '\A\{.*\}\z') { throw 'JSON stdout содержит посторонний текст.' }
            $json = Get-ValidationJson $response
            Assert-ValidationCode $json 'MANIFEST_MISSING' 'errors'
            Assert-ValidationCode $json 'STATUS_INVALID' 'errors'
            $human = Invoke-Validator $fixture -Human
            if ($human.Output -match 'успешно|ошибок нет') { throw 'Human mode содержит ложное утверждение об успехе.' }
        }
        finally { Remove-ValidationFixture $fixture }
    }
}
