$Root = Split-Path -Parent $PSScriptRoot
$SyncPath = Join-Path $Root 'current/scripts/Sync-ProjectRules.ps1'
$InitializerPath = Join-Path $Root 'current/scripts/Initialize-ProjectRules.ps1'
$CommonModulePath = Join-Path $Root 'current/scripts/Governance.Common.psm1'
$Utf8 = [Text.UTF8Encoding]::new($false)

function Copy-SyncTree { param([string]$Source, [string]$Destination) New-Item -ItemType Directory -Path $Destination -Force | Out-Null; Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force }
function Write-SyncRelease {
    param([string]$Path, [string]$Version)
    Import-Module $CommonModulePath -Force
    $hash = Get-GovernanceContentHash -RootPath $Path
    $metadata = [ordered]@{ version=$Version; channel='stable'; gitTag='v'+$Version; gitCommit=('0123456789abcdef0123456789abcdef01234567'); contentHash=$hash; releasedAt='2026-09-14T00:00:00.0000000Z' } | ConvertTo-Json
    [IO.File]::WriteAllBytes((Join-Path $Path 'version.json'), $Utf8.GetBytes($metadata+"`n"))
    $checksums = @(Get-GovernanceChecksums -RootPath $Path)
    [IO.File]::WriteAllBytes((Join-Path $Path 'checksums.sha256'), $Utf8.GetBytes(($checksums -join "`n")+"`n"))
}
function New-SyncFixture {
    $container = Join-Path ([IO.Path]::GetTempPath()) ('governance-sync-'+[guid]::NewGuid().ToString('N'))
    $repo = Join-Path $container 'repository'; $versions=Join-Path $repo 'versions'; New-Item -ItemType Directory -Path $versions -Force | Out-Null
    foreach($version in @('1.0.0','1.1.0','2.0.0')) { Copy-SyncTree (Join-Path $Root 'current/templates') (Join-Path $versions ($version+'/templates')) }
    [IO.File]::AppendAllText((Join-Path $versions '1.1.0/templates/base/docs/quality/security.md'), "`nИзменение 1.1.0.`n", $Utf8)
    [IO.File]::AppendAllText((Join-Path $versions '2.0.0/templates/base/docs/quality/test-strategy.md'), "`nИзменение 2.0.0.`n", $Utf8)
    foreach($version in @('1.0.0','1.1.0','2.0.0')) { Write-SyncRelease (Join-Path $versions $version) $version }
    $migrations=Join-Path $repo 'migrations'; New-Item -ItemType Directory -Path $migrations -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $migrations '1.0.0-to-1.1.0.md'), $Utf8.GetBytes("# Переход 1.0.0 → 1.1.0`n`nБезопасная заметка.`n"))
    $project=Join-Path $container 'project-alpha'; New-Item -ItemType Directory -Path $project -Force | Out-Null
    & $InitializerPath -RepositoryRoot $repo -ProjectPath $project -Version '1.0.0' -Overlay @('android') -Apply | Out-Null
    [PSCustomObject]@{ Container=$container; Repository=$repo; Project=$project }
}
function Remove-SyncFixture { param($Fixture) if($Fixture -and (Test-Path -LiteralPath $Fixture.Container)){[IO.Directory]::Delete($Fixture.Container,$true)} }
function Get-SyncBytes { param([string]$Path) if(Test-Path -LiteralPath $Path -PathType Leaf){return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))}; return '<absent>' }
function Invoke-Sync { param($Fixture,[switch]$Apply,[string]$Plan,[scriptblock]$BeforeWrite) & $SyncPath -RepositoryRoot $Fixture.Repository -ProjectPath $Fixture.Project -TargetVersion '2.0.0' -Apply:$Apply -ApprovedPlan $Plan -TestBeforeWrite $BeforeWrite }
function Get-SyncPlan { param($Fixture) Join-Path $Fixture.Project 'docs/plans/active/rules-migration-1.0.0-to-2.0.0.md' }
function Approve-SyncPlan { param([string]$Path) $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8; [IO.File]::WriteAllBytes($Path,$Utf8.GetBytes(($text -replace '(?m)^status: Draft$','status: Approved'))) }

Describe 'Анализ и применение миграции rules' {
    It 'анализ создаёт Draft с цепочкой и не меняет manifest или vendored rules' {
        $f=New-SyncFixture; try {
            $manifest=Join-Path $f.Project '.codex/governance/manifest.json'; $base=Join-Path $f.Project '.codex/governance/base-rules.md'; $beforeManifest=Get-SyncBytes $manifest; $beforeBase=Get-SyncBytes $base
            Invoke-Sync $f | Out-Null; $plan=Get-SyncPlan $f
            if(-not(Test-Path -LiteralPath $plan)){throw 'Draft report не создан.'}; $text=Get-Content $plan -Raw -Encoding UTF8
            if($text -notmatch 'status: Draft' -or $text -notmatch '1.1.0' -or $text -notmatch '1.0.0-to-1.1.0.md'){throw 'В отчёте отсутствует обязательная цепочка или migration note.'}
            Assert-Equal (Get-SyncBytes $manifest) $beforeManifest; Assert-Equal (Get-SyncBytes $base) $beforeBase
        } finally {Remove-SyncFixture $f}
    }
    It 'Apply без Approved plan или со stale plan не меняет проект' {
        $f=New-SyncFixture; try {
            $manifest=Join-Path $f.Project '.codex/governance/manifest.json'; $before=Get-SyncBytes $manifest
            Assert-Throws {Invoke-Sync $f -Apply} 'Approved|утвержд'
            Invoke-Sync $f | Out-Null; $plan=Get-SyncPlan $f; Approve-SyncPlan $plan
            [IO.File]::AppendAllText((Join-Path $f.Project 'docs/quality/test-strategy.md'),'локальное изменение',$Utf8)
            Assert-Throws {Invoke-Sync $f -Apply -Plan $plan} 'stale|устар|state'
            Assert-Equal (Get-SyncBytes $manifest) $before
        } finally {Remove-SyncFixture $f}
    }
    It 'Approved чистая миграция обновляет pin и сохраняет installedAt' {
        $f=New-SyncFixture; try {
            $old=(Get-Content (Join-Path $f.Project '.codex/governance/manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json)
            Invoke-Sync $f | Out-Null; $plan=Get-SyncPlan $f; Approve-SyncPlan $plan; Invoke-Sync $f -Apply -Plan $plan | Out-Null
            $new=(Get-Content (Join-Path $f.Project '.codex/governance/manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json)
            Assert-Equal $new.rulesVersion '2.0.0'; Assert-Equal $new.installedAt $old.installedAt
            if($new.updatedAt -ceq $old.updatedAt){throw 'updatedAt не изменён.'}
            $backups = @(Get-ChildItem -LiteralPath (Join-Path $f.Project '.codex/governance') -Recurse -File -Filter '*.backup-*' -ErrorAction Stop)
            if($backups.Count -ne 0){throw 'Успешная миграция оставила backup внутри governed-каталога.'}
            $transactions = @(Get-ChildItem -LiteralPath (Join-Path $f.Project '.codex') -Directory -Filter '.governance-sync-transaction-*' -ErrorAction Stop)
            if($transactions.Count -ne 0){throw 'Успешная миграция не очистила собственный transaction-каталог.'}
        } finally {Remove-SyncFixture $f}
    }
    It 'локальный конфликт сохраняется и Apply отказывается' {
        $f=New-SyncFixture; try {
            $path=Join-Path $f.Project 'docs/quality/test-strategy.md'; [IO.File]::AppendAllText($path,'локальная правка',$Utf8)
            Invoke-Sync $f | Out-Null; $plan=Get-SyncPlan $f; if((Get-Content $plan -Raw -Encoding UTF8) -notmatch 'Конфликт'){throw 'Конфликт не внесён в report.'}; Approve-SyncPlan $plan
            $before=Get-SyncBytes $path; Assert-Throws {Invoke-Sync $f -Apply -Plan $plan} 'конфликт|Conflict'; Assert-Equal (Get-SyncBytes $path) $before
        } finally {Remove-SyncFixture $f}
    }
    It 'collision report сохраняет существующие байты' {
        $f=New-SyncFixture; try { $plan=Get-SyncPlan $f; [IO.File]::WriteAllBytes($plan,$Utf8.GetBytes("---`nstatus: Draft`n---`nпользовательский отчёт`n")); $before=Get-SyncBytes $plan; Assert-Throws {Invoke-Sync $f} 'существ|collision'; Assert-Equal (Get-SyncBytes $plan) $before } finally {Remove-SyncFixture $f}
    }
    It 'validation failure откатывает собственные файлы и сохраняет concurrent state' {
        $f=New-SyncFixture; try {
            $manifest=Join-Path $f.Project '.codex/governance/manifest.json'; $base=Join-Path $f.Project '.codex/governance/base-rules.md'
            $beforeManifest=Get-SyncBytes $manifest; $beforeBase=Get-SyncBytes $base
            Invoke-Sync $f | Out-Null; $plan=Get-SyncPlan $f; Approve-SyncPlan $plan
            $concurrent=Join-Path $f.Project 'docs/concurrent-invalid.md'
            $concurrentBytes=$Utf8.GetBytes('# deliberate concurrent state'); $expectedConcurrent=[Convert]::ToBase64String($concurrentBytes)
            $inject = { [IO.File]::WriteAllBytes($concurrent,$concurrentBytes) }
            Assert-Throws {Invoke-Sync $f -Apply -Plan $plan -BeforeWrite $inject} 'Валидатор|validation'
            Assert-Equal (Get-SyncBytes $manifest) $beforeManifest; Assert-Equal (Get-SyncBytes $base) $beforeBase
            Assert-Equal (Get-SyncBytes $concurrent) $expectedConcurrent
            $transactions = @(Get-ChildItem -LiteralPath (Join-Path $f.Project '.codex') -Directory -Filter '.governance-sync-transaction-*' -ErrorAction Stop)
            if($transactions.Count -ne 0){throw 'Полный rollback должен очистить transaction-каталог.'}
        } finally {Remove-SyncFixture $f}
    }
}
