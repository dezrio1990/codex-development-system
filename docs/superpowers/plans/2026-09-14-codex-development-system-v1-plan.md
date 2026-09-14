# План реализации Codex Development System 1.0.0

> **Для агентных исполнителей:** ОБЯЗАТЕЛЬНЫЙ НАВЫК: использовать `superpowers:subagent-driven-development` (рекомендуется) или `superpowers:executing-plans` и выполнять задачи по порядку. Состояние отмечается флажками `- [ ]`.

**Цель:** создать отдельный версионируемый Git-проект системы правил, выпустить неизменяемую версию `1.0.0` и обеспечить безопасную установку, инициализацию, проверку и управляемое обновление прикладных проектов.

**Архитектура:** редактируемые материалы находятся в `current/`, а опубликованные полные снимки — в `versions/<version>/`. Проект хранит закреплённую копию правил и manifest с версией, commit и SHA-256; переход на другую версию сначала создаёт анализ влияния и применяется только после согласования.

**Технологии:** Git, GitHub, PowerShell 7 с совместимостью Windows PowerShell 5.1, Markdown, JSON, SHA-256, TOML без внешних runtime-зависимостей.

**Спецификация:** `docs/superpowers/specs/2026-09-14-codex-development-system-design.md`

## Глобальные ограничения

- Центральный remote: `https://github.com/dezrio1990/codex-development-system`.
- Локальная рабочая копия: `D:\Projects\codex-development-system`.
- Первый стабильный выпуск: `1.0.0`, Git-тег `v1.0.0`.
- Постоянная документация и объясняющие комментарии создаются на русском языке.
- Опубликованная папка версии неизменяема; исправление требует нового номера.
- Проект не обновляет правила автоматически и может оставаться на старой версии.
- Архитектура, стек, план миграции, production-зависимости и публикация требуют подтверждения пользователя.
- Для рукописного исходного кода применяется мягкий контрольный порог 500 строк.
- Опережающие абстракции разрешены только при наличии утверждённого требования, roadmap или ADR.
- Установщики не удаляют и не перезаписывают пользовательские файлы без резервной копии и явного режима применения.
- Пути конкретного компьютера не записываются в переносимые шаблоны; они передаются параметрами или конфигурацией.

---

## Карта файлов

```text
D:\Projects\codex-development-system\
├── .github/workflows/rules-ci.yml
├── AGENTS.md
├── CHANGELOG.md
├── README.md
├── support.json
├── VERSION
├── schemas/
│   ├── project-manifest.schema.json
│   ├── support.schema.json
│   └── version.schema.json
├── current/
│   ├── global/
│   │   ├── AGENTS.md
│   │   └── agents/*.toml
│   ├── templates/
│   │   ├── base/
│   │   └── overlays/{dotnet,web,android,ios,dotnet-maui}/
│   ├── scripts/
│   │   ├── Governance.Common.psm1
│   │   ├── Install-GlobalRules.ps1
│   │   ├── Initialize-ProjectRules.ps1
│   │   ├── Publish-RulesVersion.ps1
│   │   ├── Sync-ProjectRules.ps1
│   │   └── Test-ProjectRules.ps1
│   └── examples/sample-project/
├── migrations/README.md
├── tests/
│   ├── TestHarness.ps1
│   ├── Common.Tests.ps1
│   ├── Content.Tests.ps1
│   ├── Install.Tests.ps1
│   ├── Initialize.Tests.ps1
│   ├── Publish.Tests.ps1
│   ├── Sync.Tests.ps1
│   └── Validation.Tests.ps1
└── versions/1.0.0/
    ├── version.json
    ├── checksums.sha256
    └── полный снимок current/
```

`Governance.Common.psm1` владеет безопасными файловыми операциями, вычислением hash, чтением manifest и поиском версии. CLI-скрипты содержат только orchestration. Тесты запускаются собственным минимальным harness, чтобы проект не зависел от Pester.

---

### Задача 1. Создать локальный Git-проект и контракты версий

**Файлы:**

- Создать: `AGENTS.md`
- Создать: `README.md`
- Создать: `CHANGELOG.md`
- Создать: `support.json`
- Создать: `VERSION`
- Создать: `.gitignore`
- Создать: `schemas/version.schema.json`
- Создать: `schemas/project-manifest.schema.json`
- Создать: `schemas/support.schema.json`
- Создать: `tests/TestHarness.ps1`
- Создать: `tests/Common.Tests.ps1`
- Создать: `current/scripts/Governance.Common.psm1`

**Интерфейсы:**

- Производит: `Get-GovernanceVersionPath([string]$RepositoryRoot, [string]$Version) -> DirectoryInfo`.
- Производит: `Get-GovernanceManifest([string]$ProjectPath) -> PSCustomObject`.
- Производит: `Get-GovernanceChecksums([string]$RootPath) -> string[]`.
- Производит: `Get-GovernanceContentHash([string]$RootPath) -> string`.
- Производит: `Copy-GovernanceFile([string]$Source, [string]$Destination, [switch]$Replace) -> void`.

- [ ] **Шаг 1: создать `D:\Projects\codex-development-system`, инициализировать Git с веткой `main` и подтвердить, что каталог пуст кроме `.git`**

Команды:

```powershell
if (Test-Path -LiteralPath 'D:\Projects\codex-development-system') {
    throw 'Целевой каталог уже существует; требуется просмотр пользователя.'
}
New-Item -ItemType Directory -Path 'D:\Projects\codex-development-system'
git -C 'D:\Projects\codex-development-system' init -b main
git -C 'D:\Projects\codex-development-system' status --short
```

Ожидается: пустой вывод `status`; если каталог уже существует или содержит файлы, остановиться и представить их пользователю.

- [ ] **Шаг 2: написать failing-тесты общих функций**

Минимальный контракт теста:

```powershell
Describe 'Governance.Common' {
    It 'строит одинаковый SHA-256 независимо от порядка обхода файлов' {
        $first = Get-GovernanceContentHash -RootPath $fixtureA
        $second = Get-GovernanceContentHash -RootPath $fixtureB
        Assert-Equal $first $second
    }

    It 'отклоняет путь версии вне versions' {
        Assert-Throws { Get-GovernanceVersionPath $repo '..\outside' }
    }
}
```

- [ ] **Шаг 3: запустить тест и подтвердить ожидаемый FAIL из-за отсутствующего модуля**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Common.Tests.ps1
```

Ожидается: exit code `1`, функция `Get-GovernanceContentHash` не найдена.

- [ ] **Шаг 4: реализовать модуль и JSON-схемы**

Алгоритм hash:

```text
1. Получить все обычные payload-файлы рекурсивно, исключив version.json и checksums.sha256.
2. Нормализовать относительные пути к символу /.
3. Отсортировать пути ordinal-ignore-case.
4. Для каждого файла вычислить SHA-256 исходных байтов.
5. Сформировать UTF-8 без BOM: "<lowercase-hash>  <relative-path>\n".
6. SHA-256 этого списка является contentHash.
```

При расчёте release contentHash исключаются `version.json` и `checksums.sha256`, чтобы исключить циклическую зависимость. `project-manifest.schema.json` требует `schemaVersion`, `rulesSource`, `rulesVersion`, `rulesCommit`, `releaseContentHash`, `installedContentHash`, `overlays`, `installedAt`, `updatedAt`. `version.schema.json` требует `version`, `channel`, `gitTag`, `gitCommit`, `contentHash`, `releasedAt`. Изменяемые статусы `Current`, `Supported`, `Deprecated`, `Unsupported`, `Security update required` хранятся в корневом `support.json`, проверяемом через `support.schema.json`, а не внутри неизменяемых snapshots.

- [ ] **Шаг 5: запустить тесты и проверить PASS**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Common.Tests.ps1
```

Ожидается: exit code `0`, все тесты помечены `PASS`.

- [ ] **Шаг 6: зафиксировать основу**

```powershell
git add AGENTS.md README.md CHANGELOG.md support.json VERSION .gitignore schemas tests/TestHarness.ps1 tests/Common.Tests.ps1 current/scripts/Governance.Common.psm1
git commit -m "chore: initialize governance repository"
```

---

### Задача 2. Создать глобальные правила и девять ролей

**Файлы:**

- Создать: `current/global/AGENTS.md`
- Создать: `current/global/agents/frontend_developer.toml`
- Создать: `current/global/agents/ux_researcher.toml`
- Создать: `current/global/agents/ui_designer.toml`
- Создать: `current/global/agents/backend_architect.toml`
- Создать: `current/global/agents/android_developer.toml`
- Создать: `current/global/agents/ios_developer.toml`
- Создать: `current/global/agents/dotnet_maui_developer.toml`
- Создать: `current/global/agents/debugger.toml`
- Создать: `current/global/agents/code_reviewer.toml`
- Создать: `tests/Content.Tests.ps1`

**Интерфейсы:** каждый TOML содержит `name`, `description`, `developer_instructions`; read-only роли содержат `sandbox_mode = "read-only"`.

- [ ] **Шаг 1: написать failing-тест содержимого**

```powershell
It 'содержит ровно девять ролей' {
    Assert-Equal 9 (Get-ChildItem "$Root/current/global/agents/*.toml").Count
}

It 'запрещает начало существенного этапа без согласования' {
    Assert-Contains "$Root/current/global/AGENTS.md" 'явного утверждения пользователя'
}

It 'требует русскоязычную документацию' {
    Assert-Contains "$Root/current/global/AGENTS.md" 'Основной язык документации — русский'
}
```

- [ ] **Шаг 2: подтвердить FAIL из-за отсутствующих файлов**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Content.Tests.ps1
```

- [ ] **Шаг 3: перенести утверждённые универсальные правила и актуализировать роли**

Каждая роль обязана: прочитать status и активный план; соблюдать владение файлами; не менять стек и архитектуру; писать постоянную документацию на русском; сообщать фактические проверки, риски и отклонения. `ux_researcher`, `ui_designer`, `backend_architect`, `debugger`, `code_reviewer` остаются read-only.

- [ ] **Шаг 4: запустить content-тесты и проверить PASS**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Content.Tests.ps1
```

- [ ] **Шаг 5: зафиксировать правила и роли**

```powershell
git add current/global tests/Content.Tests.ps1
git commit -m "feat: add global governance rules and agent roles"
```

---

### Задача 3. Создать базовый шаблон документации проекта

**Файлы:**

- Создать: `current/templates/base/AGENTS.md`
- Создать: `current/templates/base/.codex/governance/README.md`
- Создать: `current/templates/base/docs/product/{vision,scope,roadmap}.md`
- Создать: `current/templates/base/docs/requirements/{functional,non-functional,backlog}.md`
- Создать: `current/templates/base/docs/architecture/{overview,technology-stack,data-model,integrations}.md`
- Создать: `current/templates/base/docs/architecture/decisions/ADR-template.md`
- Создать: `current/templates/base/docs/plans/templates/{active-plan,agent-task,migration-analysis}.md`
- Создать: `current/templates/base/docs/quality/{quality-gates,test-strategy,security}.md`
- Создать: `current/templates/base/docs/operations/{deployment,observability,backup-and-recovery,incident-response}.md`
- Создать: `current/templates/base/docs/status/{current,changelog}.md`
- Изменить: `tests/Content.Tests.ps1`

**Интерфейсы:** разрешённые токены шаблонов — `{{PROJECT_NAME}}`, `{{DATE}}`, `{{RULES_VERSION}}`, `{{RULES_COMMIT}}`, `{{CONTENT_HASH}}`, `{{OVERLAYS_JSON}}`.

- [ ] **Шаг 1: добавить failing-тесты полного набора шаблонов и метаданных**

```powershell
It 'каждый управляемый Markdown-шаблон начинает с метаданных' {
    foreach ($file in Get-ManagedTemplates) {
        Assert-Match (Get-Content $file -Raw) '^---\r?\n'
    }
}

It 'новые документы имеют статус Draft' {
    foreach ($file in Get-ManagedTemplates) {
        Assert-Contains $file 'status: Draft'
    }
}
```

- [ ] **Шаг 2: подтвердить FAIL**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Content.Tests.ps1
```

- [ ] **Шаг 3: создать русскоязычные шаблоны с конкретными разделами**

`current.md` содержит продукт, стек, milestone, активный план, завершённое, выполняемое, ожидающие решения, риски, проверки, следующий шаг и обязательное чтение. Активный план содержит цель, требования, scope, владение, шаги, критерии, команды, риски и журнал отклонений. ADR содержит контекст, варианты, решение, последствия и условия пересмотра.

- [ ] **Шаг 4: проверить PASS**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Content.Tests.ps1
```

- [ ] **Шаг 5: зафиксировать шаблоны**

```powershell
git add current/templates/base tests/Content.Tests.ps1
git commit -m "feat: add Russian project governance templates"
```

---

### Задача 4. Создать платформенные overlays

**Файлы:**

- Создать: `current/templates/overlays/dotnet/AGENTS.append.md`
- Создать: `current/templates/overlays/web/AGENTS.append.md`
- Создать: `current/templates/overlays/android/AGENTS.append.md`
- Создать: `current/templates/overlays/ios/AGENTS.append.md`
- Создать: `current/templates/overlays/dotnet-maui/AGENTS.append.md`
- Создать: по одному `overlay.json` в каждой папке
- Изменить: `tests/Content.Tests.ps1`

**Интерфейсы:** `overlay.json` содержит `name`, `displayName`, `version`, `targetDirectories`, `requiredTools`, `verificationCommands`.

- [ ] **Шаг 1: добавить failing-тесты пяти overlays**

```powershell
It 'каждый overlay объявляет команды проверки' {
    foreach ($overlay in Get-OverlayManifests) {
        Assert-True (($overlay.verificationCommands | Measure-Object).Count -gt 0)
    }
}
```

- [ ] **Шаг 2: подтвердить FAIL**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Content.Tests.ps1
```

- [ ] **Шаг 3: создать overlays без фиксации версии SDK проекта**

`.NET` использует `dotnet restore`, `dotnet build`, `dotnet test`; Android — Gradle wrapper; iOS — `xcodebuild` на macOS; MAUI — `dotnet workload restore` и target-specific build; web-команды берутся из утверждённого package manager и не угадываются. Каждый overlay требует сначала прочитать утверждённый `technology-stack.md`.

- [ ] **Шаг 4: проверить PASS и зафиксировать**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Content.Tests.ps1
git add current/templates/overlays tests/Content.Tests.ps1
git commit -m "feat: add platform governance overlays"
```

---

### Задача 5. Реализовать безопасную глобальную установку

**Файлы:**

- Создать: `current/scripts/Install-GlobalRules.ps1`
- Создать: `tests/Install.Tests.ps1`

**Интерфейс:**

```powershell
Install-GlobalRules.ps1 \
  -RepositoryRoot <string> \
  -Version <semver> \
  -CodexHome <string> \
  [-WhatIf]
```

- [ ] **Шаг 1: написать failing-тесты чистой, повторной и конфликтующей установки**

Проверить: создаются девять TOML; существующий `AGENTS.md` сохраняется; блок добавляется один раз; конфликтующий файл получает `.backup-<UTC timestamp>`; `-WhatIf` не меняет диск.

- [ ] **Шаг 2: подтвердить FAIL**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Install.Tests.ps1
```

- [ ] **Шаг 3: реализовать установщик через `Governance.Common.psm1`**

Установщик принимает явный `CodexHome`, запрещает корень диска и домашний каталог как рекурсивную цель, копирует только известные файлы, выводит план операций и не удаляет неизвестное содержимое.

- [ ] **Шаг 4: проверить PASS и зафиксировать**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Install.Tests.ps1
git add current/scripts/Install-GlobalRules.ps1 tests/Install.Tests.ps1
git commit -m "feat: add safe global rules installer"
```

---

### Задача 6. Реализовать инициализацию прикладного проекта

**Файлы:**

- Создать: `current/scripts/Initialize-ProjectRules.ps1`
- Создать: `tests/Initialize.Tests.ps1`

**Интерфейс:**

```powershell
Initialize-ProjectRules.ps1 \
  -RepositoryRoot <string> \
  -ProjectPath <string> \
  -Version <semver> \
  -Overlay <string[]> \
  [-Apply]
```

Без `-Apply` скрипт только показывает план. С `-Apply` он создаёт `.codex/governance`, копирует base rules и overlays, генерирует manifest, подставляет определённые токены и не заменяет существующий файл без backup.

- [ ] **Шаг 1: написать failing-тесты preview, apply и повторного запуска**

```powershell
It 'без Apply не изменяет проект' { Assert-DirectoryUnchanged $projectBefore $projectAfter }
It 'фиксирует выбранную версию и overlays' {
    Assert-Equal '1.0.0' $manifest.rulesVersion
    Assert-SequenceEqual @('dotnet','android') $manifest.overlays
}
```

- [ ] **Шаг 2: подтвердить FAIL**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Initialize.Tests.ps1
```

- [ ] **Шаг 3: реализовать инициализатор и manifest**

`rulesSource` получает URL remote, `rulesCommit` — commit выпуска, `releaseContentHash` — hash полного release payload, `installedContentHash` — hash фактически установленной комбинации base и overlays; даты записываются в UTC ISO 8601. Локальный `AGENTS.md` содержит краткое обязательство прочитать `.codex/governance/base-rules.md` перед существенной работой.

- [ ] **Шаг 4: проверить PASS и зафиксировать**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Initialize.Tests.ps1
git add current/scripts/Initialize-ProjectRules.ps1 tests/Initialize.Tests.ps1
git commit -m "feat: initialize projects from pinned rules versions"
```

---

### Задача 7. Реализовать валидатор проекта

**Файлы:**

- Создать: `current/scripts/Test-ProjectRules.ps1`
- Создать: `tests/Validation.Tests.ps1`

**Интерфейс:**

```powershell
Test-ProjectRules.ps1 -ProjectPath <string> -RepositoryRoot <string> [-Json]
```

Exit code `0` означает отсутствие ошибок; `1` — нарушение обязательного правила; warnings не меняют код возврата.

- [ ] **Шаг 1: написать failing-тесты диагностик**

Проверить коды: `MANIFEST_MISSING`, `VERSION_NOT_FOUND`, `RELEASE_HASH_MISMATCH`, `INSTALLED_HASH_MISMATCH`, `STATUS_INVALID`, `APPROVED_PLACEHOLDER`, `ACTIVE_PLAN_MISSING`, `AGENTS_TOO_LARGE`, `RUSSIAN_EXPLANATION_MISSING`, `BROKEN_REQUIRED_LINK`.

- [ ] **Шаг 2: подтвердить FAIL**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Validation.Tests.ps1
```

- [ ] **Шаг 3: реализовать проверки с читаемым русским выводом и JSON-режимом**

JSON содержит `isValid`, `errors[]`, `warnings[]`, где каждая запись имеет `code`, `path`, `message`. Проверка языка не пытается доказывать качество перевода: она требует кириллицу в постоянном документе либо ссылку на русское пояснение.

- [ ] **Шаг 4: проверить PASS и зафиксировать**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Validation.Tests.ps1
git add current/scripts/Test-ProjectRules.ps1 tests/Validation.Tests.ps1
git commit -m "feat: validate project governance state"
```

---

### Задача 8. Реализовать анализ и применение миграции правил

**Файлы:**

- Создать: `current/scripts/Sync-ProjectRules.ps1`
- Создать: `tests/Sync.Tests.ps1`
- Создать: `migrations/README.md`

**Интерфейс:**

```powershell
Sync-ProjectRules.ps1 \
  -RepositoryRoot <string> \
  -ProjectPath <string> \
  -TargetVersion <semver> \
  [-Apply] \
  [-ApprovedPlan <string>]
```

Без `-Apply` создаётся русский отчёт `docs/plans/active/rules-migration-<from>-to-<to>.md`. Применение требует `-ApprovedPlan`, чей status равен `Approved`.

- [ ] **Шаг 1: написать failing-тесты перехода, отказа и неизменности старого проекта**

Проверить: анализ не меняет manifest; apply без утверждённого плана завершается ошибкой; переход обновляет hash только после копирования и валидации; отклонения проекта не перезаписываются.

- [ ] **Шаг 2: подтвердить FAIL**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Sync.Tests.ps1
```

- [ ] **Шаг 3: реализовать cumulative diff всех промежуточных версий**

Отчёт содержит изменения правил, новые обязательства, удалённые правила, локальные конфликты, влияние на документацию, код и CI, риски, шаги и откат. Если миграционного файла нет, строится файловый diff и выводится предупреждение.

- [ ] **Шаг 4: проверить PASS и зафиксировать**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Sync.Tests.ps1
git add current/scripts/Sync-ProjectRules.ps1 tests/Sync.Tests.ps1 migrations/README.md
git commit -m "feat: analyze and apply rules migrations"
```

---

### Задача 9. Реализовать механизм публикации неизменяемых версий

**Файлы:**

- Создать: `current/scripts/Publish-RulesVersion.ps1`
- Создать: `tests/Publish.Tests.ps1`

**Интерфейс:**

```powershell
Publish-RulesVersion.ps1 \
  -RepositoryRoot <string> \
  -Version 1.0.0 \
  -Status Current \
  [-Apply]
```

- [ ] **Шаг 1: написать failing-тесты preview, публикации и запрета изменения существующей версии**

Проверить: без `-Apply` нет файлов; выпуск копирует полный `current`; повторная публикация `1.0.0` отклоняется даже при одинаковом содержимом; checksums воспроизводимы.

- [ ] **Шаг 2: подтвердить FAIL**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Publish.Tests.ps1
```

- [ ] **Шаг 3: реализовать publisher**

`version.json` записывает version, `channel=stable`, `gitTag=v<version>`, текущий commit, contentHash и UTC-даты. `checksums.sha256` перечисляет payload-файлы снимка, исключая `version.json` и сам список; корневой `support.json` получает исходный статус выпуска и может изменяться в последующих коммитах без изменения snapshot.

- [ ] **Шаг 4: проверить publisher на временных fixture-репозиториях**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\*.Tests.ps1
```

Ожидается: все suites PASS; основной каталог `versions/1.0.0` ещё не создан.

- [ ] **Шаг 5: зафиксировать механизм публикации**

```powershell
git status --short
git diff --check
git add current/scripts/Publish-RulesVersion.ps1 tests/Publish.Tests.ps1
git commit -m "feat: publish immutable governance versions"
```

---

### Задача 10. Создать пример, CI и эксплуатационную документацию

**Файлы:**

- Создать: `current/examples/sample-project/**`
- Создать: `.github/workflows/rules-ci.yml`
- Изменить: `README.md`
- Изменить: `CHANGELOG.md`
- Создать: `docs/maintenance.md`
- Создать: `docs/release-process.md`

**Интерфейсы:** CI запускает все `tests/*.Tests.ps1`, проверяет `versions/**/checksums.sha256` и запрещает изменение ранее опубликованного snapshot относительно основной ветки.

- [ ] **Шаг 1: создать failing end-to-end тест сценария sample-project**

```text
инициализация 1.0.0 с dotnet+android
→ проверка manifest и hash
→ проверка русских документов
→ повторная инициализация без изменений
→ анализ фиктивной будущей миграции без применения
```

- [ ] **Шаг 2: подтвердить FAIL, затем создать пример и workflow**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\Initialize.Tests.ps1 .\tests\Validation.Tests.ps1 .\tests\Sync.Tests.ps1
```

- [ ] **Шаг 3: описать русские инструкции сопровождения и выпуска**

README содержит установку, создание проекта на выбранной версии, проверку, обновление и откат. `maintenance.md` описывает предложение правила и классификацию global/project-specific. `release-process.md` описывает review, подтверждение пользователя, неизменяемый snapshot, tag и changelog.

- [ ] **Шаг 4: выполнить полную проверку**

```powershell
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\*.Tests.ps1
git diff --check
git status --short
```

- [ ] **Шаг 5: зафиксировать пример и CI**

```powershell
git add current/examples .github README.md CHANGELOG.md docs
git commit -m "docs: add verified governance workflow and CI"
```

- [ ] **Шаг 6: создать и проверить финальный снимок 1.0.0**

```powershell
pwsh -NoProfile -File .\current\scripts\Publish-RulesVersion.ps1 -RepositoryRoot . -Version 1.0.0 -Status Current -Apply
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\*.Tests.ps1
pwsh -NoProfile -File .\current\scripts\Test-ProjectRules.ps1 -ProjectPath .\current\examples\sample-project -RepositoryRoot .
```

Ожидается: создан `versions/1.0.0`, все suites PASS, validator возвращает `0`.

- [ ] **Шаг 7: зафиксировать выпуск и поставить тег после просмотра diff**

```powershell
git status --short
git diff --check
git add versions/1.0.0 support.json VERSION CHANGELOG.md
git commit -m "release: publish governance rules 1.0.0"
git tag -a v1.0.0 -m "Codex Development System 1.0.0"
```

---

### Задача 11. Создать приватный GitHub remote и опубликовать 1.0.0

**Файлы:** GitHub-репозиторий `dezrio1990/codex-development-system`; локальная Git-конфигурация remote.

**Предусловие:** отдельное явное разрешение пользователя на создание удалённого репозитория и push; подтверждённая аутентификация GitHub.

- [ ] **Шаг 1: проверить финальное состояние без изменения внешних систем**

```powershell
git status --short
git log --oneline --decorate -10
git show-ref --verify refs/tags/v1.0.0
git cat-file -t v1.0.0
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\*.Tests.ps1
```

Ожидается: чистая рабочая копия, `cat-file` возвращает `tag`, все тесты PASS.

- [ ] **Шаг 2: представить пользователю remote URL, видимость `private`, ветку `main`, список коммитов и результаты тестов**

- [ ] **Шаг 3: после отдельного подтверждения создать remote**

```powershell
gh repo create dezrio1990/codex-development-system --private --source 'D:\Projects\codex-development-system' --remote origin
```

Если `gh` отсутствует или не аутентифицирован, использовать GitHub UI только после входа пользователя; не запрашивать и не выводить token.

- [ ] **Шаг 4: push ветки и тега**

```powershell
git -C 'D:\Projects\codex-development-system' push -u origin main
git -C 'D:\Projects\codex-development-system' push origin v1.0.0
```

- [ ] **Шаг 5: проверить удалённое состояние**

```powershell
git -C 'D:\Projects\codex-development-system' ls-remote --heads --tags origin
```

Ожидается: `refs/heads/main` и `refs/tags/v1.0.0` указывают на опубликованные объекты.

---

## Контрольные точки пользователя

1. Перед задачей 1: утверждение этого плана и разрешение создать локальный репозиторий по указанному пути.
2. После задачи 4: просмотр содержания глобальных правил, ролей, базовых шаблонов и overlays.
3. После задачи 8: просмотр поведения установки, инициализации, проверки и миграции.
4. Перед тегом `v1.0.0`: утверждение release candidate.
5. Перед задачей 11: отдельное разрешение создать приватный GitHub-репозиторий и выполнить push.

## Итоговая проверка

```powershell
Set-Location 'D:\Projects\codex-development-system'
pwsh -NoProfile -File .\tests\TestHarness.ps1 .\tests\*.Tests.ps1
pwsh -NoProfile -File .\current\scripts\Test-ProjectRules.ps1 -ProjectPath .\current\examples\sample-project -RepositoryRoot .
git diff --check
git status --short
git show-ref --verify refs/tags/v1.0.0
git cat-file -t v1.0.0
```

Готовность подтверждается только свежим выводом: все тесты PASS, validator возвращает `0`, `git diff --check` не находит ошибок, рабочая копия чиста, `git cat-file -t` подтверждает аннотированный тег, а remote содержит `main` и `v1.0.0`.
