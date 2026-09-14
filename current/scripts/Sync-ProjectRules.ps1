[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [Parameter(Mandatory = $true)][string]$TargetVersion,
    [switch]$Apply,
    [string]$ApprovedPlan,
    [Parameter(DontShow = $true)][scriptblock]$TestBeforeWrite
)

Set-StrictMode -Version Latest

$utf8 = [Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $PSScriptRoot
$initializer = Join-Path $PSScriptRoot 'Initialize-ProjectRules.ps1'
$validator = Join-Path $PSScriptRoot 'Test-ProjectRules.ps1'
$semVer = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

function Test-Bytes { param($Left,$Right) if($null -eq $Left -or $null -eq $Right){return $null -eq $Left -and $null -eq $Right}; return [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($Left,$Right) }
function Get-BytesOrNull { param([string]$Path) if(Test-Path -LiteralPath $Path -PathType Leaf){return [IO.File]::ReadAllBytes($Path)}; return $null }
function Get-Sha { param([byte[]]$Bytes) $hash=[Security.Cryptography.SHA256]::Create(); try{return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()} }
function Compare-SemVer {
    param([string]$Left,[string]$Right)
    if($Left -cnotmatch $semVer -or $Right -cnotmatch $semVer){throw 'Версия должна соответствовать строгому SemVer.'}
    $a=$Left.Split('+')[0].Split('-',2); $b=$Right.Split('+')[0].Split('-',2); $ap=$a[0].Split('.'); $bp=$b[0].Split('.')
    for($i=0;$i -lt 3;$i++){ $c=[bigint]::Parse($ap[$i]).CompareTo([bigint]::Parse($bp[$i])); if($c -ne 0){return $c} }
    if($a.Count -eq 1 -and $b.Count -eq 1){return 0}; if($a.Count -eq 1){return 1}; if($b.Count -eq 1){return -1}
    $aa=$a[1].Split('.'); $bb=$b[1].Split('.'); for($i=0;$i -lt [Math]::Max($aa.Count,$bb.Count);$i++){if($i -ge $aa.Count){return -1};if($i -ge $bb.Count){return 1};$an=$aa[$i] -match '^\d+$';$bn=$bb[$i] -match '^\d+$';if($an -and $bn){$c=[bigint]::Parse($aa[$i]).CompareTo([bigint]::Parse($bb[$i]));if($c -ne 0){return $c}}elseif($an){return -1}elseif($bn){return 1}else{$c=[string]::CompareOrdinal($aa[$i],$bb[$i]);if($c -ne 0){return $c}}};return 0
}
function Get-FrontMatter {
    param([string]$Text,[string]$Description)
    if($Text -notmatch '(?s)\A---\r?\n(?<front>.*?)\r?\n---\r?\n'){throw "$Description не содержит ровно один bounded front matter."}
    if([regex]::Matches($Text,'(?m)^---\s*$').Count -ne 2){throw "$Description содержит лишний front matter."}
    $map=@{}; foreach($line in $Matches.front -split '\r?\n'){if($line -notmatch '^(?<k>[a-z_]+): (?<v>[^\r\n]+)$' -or $map.ContainsKey($Matches.k)){throw "$Description содержит некорректное поле."};$map[$Matches.k]=$Matches.v}; return $map
}
function Assert-SafeFile { param([string]$Path,[string]$Container)
    $full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetFullPath($Container).TrimEnd([char]92,[char]47)+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $full -PathType Leaf)){throw "Небезопасный или отсутствующий файл: $Path"}
    $cursor=$full;while($true){$item=Get-Item -LiteralPath $cursor -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Reparse point запрещён: $cursor"};$parent=Split-Path -Parent $cursor;if([string]::IsNullOrWhiteSpace($parent)-or $parent -ceq $cursor){break};$cursor=$parent}
    return $full
}
function Invoke-Validation { param([string]$Repository,[string]$Project)
    $engineName=$(if($PSVersionTable.PSEdition -ceq 'Core'){'pwsh.exe'}else{'powershell.exe'})
    $engine=Join-Path $PSHome $engineName
    $out=@(& $engine -NoProfile -File $validator -ProjectPath $Project -RepositoryRoot $Repository -Json 2>&1 | ForEach-Object {[string]$_});$exit=$LASTEXITCODE
    try{$json=([string]::Join("`n",$out)|ConvertFrom-Json -ErrorAction Stop)}catch{throw "Валидатор не вернул JSON: $($_.Exception.Message)"}
    return [PSCustomObject]@{ ExitCode=$exit; Json=$json }
}
function Assert-Release {
    param([string]$Repository,[string]$Version,[string[]]$Overlays,[string]$Leaf)
    $release=Join-Path $Repository ('versions/'+$Version); Assert-SafeFile (Join-Path $release 'version.json') $Repository | Out-Null; Assert-SafeFile (Join-Path $release 'checksums.sha256') $Repository | Out-Null
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('governance-sync-stage-'+[guid]::NewGuid().ToString('N'));$stage=Join-Path $temp $Leaf
    try { New-Item -ItemType Directory -Path $stage -Force | Out-Null; & $initializer -RepositoryRoot $Repository -ProjectPath $stage -Version $Version -Overlay $Overlays -Apply | Out-Null; $check=Invoke-Validation $Repository $stage;if($check.ExitCode -ne 0){throw "Выпуск $Version не прошёл structural validation."};$metadata=Get-Content (Join-Path $release 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json;return [PSCustomObject]@{Path=$release;Metadata=$metadata} }
    finally {if(Test-Path -LiteralPath $temp){[IO.Directory]::Delete($temp,$true)}}
}
function Render { param([byte[]]$Bytes,[hashtable]$Tokens) $text=$utf8.GetString($Bytes);foreach($key in $Tokens.Keys){$text=$text.Replace('{{'+$key+'}}',[string]$Tokens[$key])};if($text -match '\{\{[^}]+\}\}'){throw 'В шаблоне остался token.'};return ,$utf8.GetBytes($text) }
function Get-Tokens { param($Manifest,$Metadata,[string]$Date)
    return @{PROJECT_NAME=(Split-Path -Leaf $project);DATE=$Date;RULES_VERSION=$Metadata.version;RULES_COMMIT=$Metadata.gitCommit;CONTENT_HASH=$Metadata.contentHash;OVERLAYS_JSON=(ConvertTo-Json -InputObject @($Manifest.overlays) -Compress)}
}
function Get-TemplateMap {
    param([string]$Release,$Manifest,[string]$Date)
    $metadata=Get-Content (Join-Path $Release 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json;$tokens=Get-Tokens $Manifest $metadata $Date;$map=@{}
    $base=Join-Path $Release 'templates/base';foreach($file in Get-ChildItem -LiteralPath $base -Recurse -File -Force){$relative=$file.FullName.Substring($base.Length).TrimStart([char]92,[char]47).Replace('\','/');$destination=$(if($relative -ceq 'AGENTS.md'){'.codex/governance/base-rules.md'}else{$relative});$raw=[IO.File]::ReadAllBytes($file.FullName);$null=$map[$destination]=$(if($file.Extension -ceq '.md'){Render $raw $tokens}else{$raw})}
    $rootLines=@('# Правила запуска проекта','','Перед существенной работой обязательно прочитайте:','- `.codex/governance/base-rules.md`.');foreach($name in @($Manifest.overlays|Sort-Object)){$null=$rootLines+='- `.codex/governance/overlays/'+$name+'.md`.'};$null=$rootLines+=@('','Эти закреплённые правила дополняют существующие применимые правила и не отменяют их.');$null=$map['AGENTS.md']=$utf8.GetBytes(($rootLines -join "`n")+"`n")
    foreach($name in @($Manifest.overlays)){ $path=Join-Path $Release ('templates/overlays/'+$name+'/AGENTS.append.md');$null=$map['.codex/governance/overlays/'+$name+'.md']=Render ([IO.File]::ReadAllBytes($path)) $tokens }
    return ,$map
}
function Get-ProjectStateHash { param([string]$ManifestPath,[hashtable]$Paths)
    $lines=@('manifest '+(Get-Sha ([IO.File]::ReadAllBytes($ManifestPath))));foreach($name in @($Paths.Keys|Sort-Object)){ $bytes=Get-BytesOrNull (Join-Path $project $name);$value=$(if($null -eq $bytes){'<absent>'}else{Get-Sha $bytes});$lines+='file '+$name+' '+$value};return Get-Sha $utf8.GetBytes(($lines -join "`n")+"`n")
}
function Get-Analysis {
    $check=Invoke-Validation $repository $project;if($check.ExitCode -ne 0){throw ('Исходный проект содержит errors валидатора; миграция запрещена: '+(@($check.Json.errors|ForEach-Object{$_.code+':'+$_.message})-join ','))}
    $manifest=Get-Content (Join-Path $project '.codex/governance/manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json;$from=[string]$manifest.rulesVersion
    if((Compare-SemVer $TargetVersion $from) -le 0){throw 'Команда поддерживает только upgrade на более новую версию.'}
    $folders=@(Get-ChildItem -LiteralPath (Join-Path $repository 'versions') -Directory|Where-Object{$_.Name -cmatch $semVer}|Sort-Object @{Expression={$_.Name};Ascending=$true});$versions=@($folders|ForEach-Object{$_.Name}|Where-Object{(Compare-SemVer $_ $from) -gt 0 -and (Compare-SemVer $_ $TargetVersion) -le 0}|Sort-Object {[version]($_.Split('-')[0])})
    if($versions.Count -eq 0 -or $versions[-1] -cne $TargetVersion){throw 'Целевой выпуск не опубликован или цепочка недоступна.'}
    foreach($version in $versions){Assert-Release $repository $version @($manifest.overlays) (Split-Path -Leaf $project)|Out-Null}
    $installedDate=([DateTimeOffset]$manifest.installedAt).ToUniversalTime().ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $old=Get-TemplateMap (Join-Path $repository ('versions/'+$from)) $manifest $installedDate;$new=Get-TemplateMap (Join-Path $repository ('versions/'+$TargetVersion)) $manifest ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
    $affected=@{};foreach($name in @($old.Keys)+@($new.Keys)){$null=$affected[$name]=$true};$conflicts=[Collections.Generic.List[string]]::new();$changes=[Collections.Generic.List[string]]::new()
    foreach($name in @($affected.Keys|Sort-Object)){$current=Get-BytesOrNull (Join-Path $project $name);$oldBytes=$(if($old.ContainsKey($name)){$old[$name]}else{$null});$newBytes=$(if($new.ContainsKey($name)){$new[$name]}else{$null});$sameOld=($null -eq $current -and $null -eq $oldBytes) -or ($null -ne $current -and $null -ne $oldBytes -and (Test-Bytes $current $oldBytes));$sameUpstream=($null -eq $oldBytes -and $null -eq $newBytes) -or ($null -ne $oldBytes -and $null -ne $newBytes -and (Test-Bytes $oldBytes $newBytes));if(-not $sameOld -and -not $sameUpstream){$null=$conflicts.Add($name)};if(-not $sameUpstream){$null=$changes.Add($name)}}
    $notes=[Collections.Generic.List[string]]::new();$previous=$from;foreach($version in $versions){$note=Join-Path $repository ('migrations/'+$previous+'-to-'+$version+'.md');if(Test-Path -LiteralPath $note -PathType Leaf){Assert-SafeFile $note $repository|Out-Null;$null=$notes.Add("$previous -> ${version}: $([IO.Path]::GetFileName($note))")}else{$null=$notes.Add("$previous -> ${version}: WARNING fallback file diff")};$previous=$version}
    $target=Get-Content (Join-Path $repository ('versions/'+$TargetVersion+'/version.json')) -Raw -Encoding UTF8|ConvertFrom-Json
    return [PSCustomObject]@{Manifest=$manifest;From=$from;Target=$target;Versions=$versions;Old=$old;New=$new;Affected=$affected;Conflicts=@($conflicts);Changes=@($changes);Notes=@($notes);StateHash=(Get-ProjectStateHash (Join-Path $project '.codex/governance/manifest.json') $affected)}
}
function New-Report { param($Analysis,[string]$Path)
    $front=@('---','status: Draft',('migration_from: {0}' -f [string]$Analysis.From),('migration_to: {0}' -f $TargetVersion),('source_release_hash: {0}' -f [string]$Analysis.Manifest.releaseContentHash),('target_release_hash: {0}' -f [string]$Analysis.Target.contentHash),('overlays: {0}' -f (@($Analysis.Manifest.overlays|Sort-Object)-join ',')),('project_state_hash: {0}' -f [string]$Analysis.StateHash),'generated_by: Sync-ProjectRules.ps1','schema_version: 1',('created: {0}' -f [DateTime]::UtcNow.ToString('o')),('updated: {0}' -f [DateTime]::UtcNow.ToString('o')),'---')
    $body=@(('# Анализ миграции правил {0} → {1}' -f [string]$Analysis.From,$TargetVersion),'','## Цель','Переход выполняется только после явного утверждения этого плана пользователем.','','## Цепочка версий')+($Analysis.Versions|ForEach-Object{'- '+$_})+@('','## Изменения и migration notes')+($Analysis.Notes|ForEach-Object{'- '+$_})+@('','## Локальные конфликты')+$(if($Analysis.Conflicts.Count){$Analysis.Conflicts|ForEach-Object{'- Конфликт: '+$_}}else{'- Конфликтов не обнаружено.'})+@('','## Влияние на документацию, код и CI','- Скрипт изменяет только governed templates и vendored rules; код приложения и CI не редактируются автоматически.','','## Риски и prerequisites','- Перед Apply повторяются preflight, integrity и binding; при любом отклонении требуется новый анализ.','','## Пошаговое применение','1. Пользователь меняет только `status: Draft` на `status: Approved`.','2. Запустить Sync с `-Apply -ApprovedPlan` для этого файла.','3. Скрипт валидирует результат и откатывает собственные изменения при ошибке.','','## Фактические проверки','- Анализ не выполняет build или тесты приложения; они остаются задачей утверждённого проекта.','','## Откат','- Используйте отдельную ветку и commit; скрипт также восстанавливает свои файловые операции при неуспехе.','','## Решения пользователя','- Ожидается явное утверждение данного плана.')
    $content = ((@($front) + @('') + @($body)) -join "`n") + "`n"
    [IO.File]::WriteAllBytes($Path,$utf8.GetBytes($content))
}
function Assert-PlanBinding { param($Analysis,[string]$PlanPath)
    $full=Assert-SafeFile $PlanPath (Join-Path $project 'docs/plans/active');$front=Get-FrontMatter (Get-Content $full -Raw -Encoding UTF8) 'ApprovedPlan';if($front.status -cne 'Approved'){throw 'ApprovedPlan не имеет status: Approved.'}
    $expected=@{migration_from=$Analysis.From;migration_to=$TargetVersion;source_release_hash=$Analysis.Manifest.releaseContentHash;target_release_hash=$Analysis.Target.contentHash;overlays=(@($Analysis.Manifest.overlays|Sort-Object)-join ',');project_state_hash=$Analysis.StateHash;generated_by='Sync-ProjectRules.ps1';schema_version='1'};foreach($key in $expected.Keys){if(-not $front.ContainsKey($key)-or $front[$key] -cne $expected[$key]){throw "ApprovedPlan stale или имеет чужой binding: $key"}};return $full
}
function Get-OrdinalSortedStrings {
    param([string[]]$Values)

    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}
function Get-InstalledHash {
    param([hashtable]$Map)

    $names = Get-OrdinalSortedStrings @($Map.Keys | Where-Object {
        $_ -ceq '.codex/governance/base-rules.md' -or $_ -clike '.codex/governance/overlays/*'
    })
    $lines = foreach ($name in $names) {
        $relative = $name.Substring('.codex/governance/'.Length)
        (Get-Sha $Map[$name]) + '  ' + $relative
    }
    return Get-Sha ($utf8.GetBytes(($lines -join "`n") + "`n"))
}
function Write-TransactionJournal {
    param([string]$JournalPath, [string]$State, [object[]]$Entries)

    $payload = [ordered]@{
        schemaVersion = 1
        state = $State
        entries = @($Entries | ForEach-Object {
            [ordered]@{ target = $_.Path; backup = $_.Backup; hadOriginal = $_.HadOriginal }
        })
    } | ConvertTo-Json -Depth 4
    $temporary = $JournalPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllBytes($temporary, $utf8.GetBytes($payload + "`n"))
    if (Test-Path -LiteralPath $JournalPath -PathType Leaf) {
        [IO.File]::Delete($JournalPath)
    }
    [IO.File]::Move($temporary, $JournalPath)
}
function Restore-Transaction {
    param([object[]]$Entries)

    $complete = $true
    for ($index = $Entries.Count - 1; $index -ge 0; $index--) {
        $entry = $Entries[$index]
        $current = Get-BytesOrNull $entry.Path
        if ($entry.HadOriginal) {
            if ($null -ne $current -and (Test-Bytes $current $entry.New)) {
                [IO.File]::Delete($entry.Path)
                $current = $null
            }
            if ($null -eq $current -and (Test-Path -LiteralPath $entry.Backup -PathType Leaf)) {
                [IO.File]::Copy($entry.Backup, $entry.Path, $false)
            }
            elseif ($null -ne $current -and -not (Test-Bytes $current $entry.Old)) {
                $complete = $false
            }
        }
        elseif ($null -ne $current) {
            if (Test-Bytes $current $entry.New) {
                [IO.File]::Delete($entry.Path)
            }
            else {
                $complete = $false
            }
        }
    }
    return $complete
}
function Apply-Operations {
    param($Analysis)

    # Staging находится рядом с governance, но вне его: валидатор намеренно
    # отвергает любые дополнительные файлы внутри .codex/governance.
    $transaction = Join-Path $project ('.codex/.governance-sync-transaction-' + [guid]::NewGuid().ToString('N'))
    $backupRoot = Join-Path $transaction 'backups'
    $journalPath = Join-Path $transaction 'journal.json'
    $journal = [Collections.Generic.List[object]]::new()
    $temporaryFiles = [Collections.Generic.List[string]]::new()
    $operations = @()
    foreach ($name in Get-OrdinalSortedStrings @($Analysis.Changes)) {
        $targetPath = Join-Path $project $name
        $old = Get-BytesOrNull $targetPath
        $new = if ($Analysis.New.ContainsKey($name)) { $Analysis.New[$name] } else { $null }
        $operations += [PSCustomObject]@{ Path=$targetPath; Old=$old; New=$new; HadOriginal=($null -ne $old); Backup=$null }
    }

    $updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $manifest = $Analysis.Manifest
    $manifest.rulesVersion = $TargetVersion
    $manifest.rulesCommit = $Analysis.Target.gitCommit
    $manifest.releaseContentHash = $Analysis.Target.contentHash
    $manifest.updatedAt = $updated
    $manifestPath = Join-Path $project '.codex/governance/manifest.json'
    $operations += [PSCustomObject]@{ Path=$manifestPath; Old=Get-BytesOrNull $manifestPath; New=$null; HadOriginal=$true; Backup=$null }

    try {
        New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null
        foreach ($op in $operations) {
            if ($op.Path -ceq $manifestPath) {
                $actual = @{}
                $actual['.codex/governance/base-rules.md'] = [IO.File]::ReadAllBytes((Join-Path $project '.codex/governance/base-rules.md'))
                foreach ($overlay in @($Analysis.Manifest.overlays)) {
                    $relative = '.codex/governance/overlays/' + $overlay + '.md'
                    $actual[$relative] = [IO.File]::ReadAllBytes((Join-Path $project $relative))
                }
                $manifest.installedContentHash = Get-InstalledHash $actual
                $op.New = $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 4) + "`n")
            }
            if ($null -ne $TestBeforeWrite) { & $TestBeforeWrite }
            $now = Get-BytesOrNull $op.Path
            if (($null -eq $now) -ne ($null -eq $op.Old) -or ($null -ne $now -and -not (Test-Bytes $now $op.Old))) {
                throw "TOCTOU: destination изменился: $($op.Path)"
            }
            $directory = Split-Path -Parent $op.Path
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
            }
            if ($null -ne $op.New) {
                $temporary = Join-Path $directory ('.governance.tmp-' + [guid]::NewGuid().ToString('N'))
                $temporaryFiles.Add($temporary) | Out-Null
                [IO.File]::WriteAllBytes($temporary, $op.New)
            }
            if ($op.HadOriginal) {
                $op.Backup = Join-Path $backupRoot ($journal.Count.ToString('D4') + '.bin')
                [IO.File]::Copy($op.Path, $op.Backup, $false)
            }
            $journal.Add($op) | Out-Null
            Write-TransactionJournal -JournalPath $journalPath -State 'applying' -Entries @($journal)
            if ($op.HadOriginal) {
                [IO.File]::Delete($op.Path)
            }
            if ($null -ne $op.New) {
                [IO.File]::Move($temporary, $op.Path)
                $temporaryFiles.Remove($temporary) | Out-Null
            }
        }
        $check = Invoke-Validation $repository $project
        if ($check.ExitCode -ne 0) {
            throw ('Валидатор не подтвердил миграцию: ' + (@($check.Json.errors | ForEach-Object { $_.code }) -join ','))
        }
        # Удаляем только каталоги, созданные этой операцией, и только после validation.
        [IO.Directory]::Delete($transaction, $true)
    }
    catch {
        $failure = $_
        foreach ($temporary in @($temporaryFiles)) {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        }
        $rolledBack = Restore-Transaction -Entries @($journal)
        if ($rolledBack -and (Test-Path -LiteralPath $transaction -PathType Container)) {
            [IO.Directory]::Delete($transaction, $true)
        }
        if (-not $rolledBack) {
            throw ("$($failure.Exception.Message) Откат не завершён; каталог восстановления: $transaction")
        }
        throw $failure
    }
}

$repository=[IO.Path]::GetFullPath($RepositoryRoot);$project=[IO.Path]::GetFullPath($ProjectPath);if(-not(Test-Path -LiteralPath $repository -PathType Container) -or -not(Test-Path -LiteralPath $project -PathType Container)){throw 'RepositoryRoot и ProjectPath должны существовать.'};if($TargetVersion -cnotmatch $semVer){throw 'TargetVersion должен быть SemVer.'}
$analysis=Get-Analysis;$planPath=Join-Path $project ('docs/plans/active/rules-migration-'+$analysis.From+'-to-'+$TargetVersion+'.md')
if(-not $Apply){if(Test-Path -LiteralPath $planPath -PathType Leaf){$front=Get-FrontMatter (Get-Content $planPath -Raw -Encoding UTF8) 'Существующий report';if($front.status -cne 'Draft' -or -not $front.ContainsKey('project_state_hash') -or $front.project_state_hash -cne $analysis.StateHash){throw 'Report уже существует и не является идентичным Draft; архивируйте или переименуйте его.'}}else{New-Item -ItemType Directory -Path (Split-Path -Parent $planPath) -Force|Out-Null;New-Report $analysis $planPath};Write-Output ([PSCustomObject]@{Action='Analyzed';Report=$planPath;Conflicts=$analysis.Conflicts});return}
if([string]::IsNullOrWhiteSpace($ApprovedPlan)){throw 'Для Apply обязателен ApprovedPlan.'};Assert-PlanBinding $analysis $ApprovedPlan|Out-Null;if($analysis.Conflicts.Count -gt 0){throw ('Обнаружены локальные конфликты; Apply запрещён до нового согласованного анализа: '+($analysis.Conflicts -join ','))};Apply-Operations $analysis;Write-Output ([PSCustomObject]@{Action='Applied';Version=$TargetVersion})
