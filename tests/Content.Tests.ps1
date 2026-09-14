$Root = Split-Path -Parent $PSScriptRoot
$GlobalRulesPath = Join-Path $Root 'current/global/AGENTS.md'
$AgentsPath = Join-Path $Root 'current/global/agents'
$BaseTemplatesPath = Join-Path $Root 'current/templates/base'
$OverlaysPath = Join-Path $Root 'current/templates/overlays'

function Assert-OrdinalSequenceEqual {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Actual,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Expected
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "Ожидалось элементов: $($Expected.Count), получено: $($Actual.Count)."
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if (-not [System.StringComparer]::Ordinal.Equals($Actual[$index], $Expected[$index])) {
            throw "Элемент с индексом $index не совпадает: ожидалось '$($Expected[$index])', получено '$($Actual[$index])'."
        }
    }
}

function Get-OverlayManifests {
    if (-not (Test-Path -LiteralPath $OverlaysPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $OverlaysPath -Directory -ErrorAction Stop |
        Sort-Object -Property Name |
        ForEach-Object {
            $manifestPath = Join-Path $_.FullName 'overlay.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                throw "Overlay '$($_.Name)' не содержит overlay.json."
            }

            [PSCustomObject]@{
                Directory = $_
                Path = $manifestPath
                Value = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
        })
}

function Assert-SafeOverlayTargetDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or [System.IO.Path]::IsPathRooted($Path)) {
        throw "Путь применения overlay должен быть непустым относительным путём: '$Path'."
    }

    if ($Path -ne '.' -and ($Path.Contains('\') -or $Path -match '(^|/)\.\.?($|/)' -or $Path -match '[:<>"|?*]')) {
        throw "Путь применения overlay небезопасен или непереносим: '$Path'."
    }
}

function Get-ManagedTemplates {
    if (-not (Test-Path -LiteralPath $BaseTemplatesPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $BaseTemplatesPath -Recurse -File -Filter '*.md' -ErrorAction Stop |
        Sort-Object -Property FullName)
}

function Assert-TextContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )

    if ($Text.IndexOf($ExpectedText, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Не найден обязательный текст: '$ExpectedText'."
    }
}

function Assert-TextMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if ($Text -notmatch $Pattern) {
        throw "Текст не соответствует обязательному шаблону '$Pattern'."
    }
}

function Assert-TextNotMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if ($Text -match $Pattern) {
        throw "Текст соответствует запрещённому шаблону '$Pattern'."
    }
}

function Assert-MarkdownTablesHaveMatchingColumnCounts {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tables = @()
    $currentTable = @()
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop) {
        if ($line -match '^\|.*\|\s*$') {
            $currentTable += $line
            continue
        }

        if ($currentTable.Count -gt 0) {
            $tables += ,@($currentTable)
            $currentTable = @()
        }
    }

    if ($currentTable.Count -gt 0) {
        $tables += ,@($currentTable)
    }

    if ($tables.Count -eq 0) {
        throw "В '$Path' не найдено Markdown-таблиц."
    }

    foreach ($table in $tables) {
        if ($table.Count -lt 3) {
            throw "В '$Path' Markdown-таблица должна содержать header, separator и строку примера."
        }

        $headerCount = $table[0].Trim().Trim('|').Split('|').Count
        for ($index = 1; $index -lt $table.Count; $index++) {
            $rowCount = $table[$index].Trim().Trim('|').Split('|').Count
            if ($rowCount -ne $headerCount) {
                throw "В '$Path' строка таблицы с индексом $index содержит $rowCount колонок при $headerCount колонках header."
            }
        }
    }
}

function Get-RoleToml {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
    $properties = @{}

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -notmatch '^([a-z_]+) = "([^"\\\x00-\x1F\x7F]+)"$') {
            throw "Файл '$Path' не соответствует строгому используемому TOML-подмножеству ключ = строка без escape-последовательностей."
        }

        $key = $Matches[1]
        $value = $Matches[2]
        if ($properties.ContainsKey($key)) {
            throw "Файл '$Path' содержит повторный ключ '$key'."
        }

        $properties[$key] = $value
    }

    return $properties
}

Describe 'Глобальные правила и роли' {
    It 'содержит ровно девять ожидаемых ролей' {
        $expected = @(
            'frontend_developer.toml',
            'ux_researcher.toml',
            'ui_designer.toml',
            'backend_architect.toml',
            'android_developer.toml',
            'ios_developer.toml',
            'dotnet_maui_developer.toml',
            'debugger.toml',
            'code_reviewer.toml'
        )

        $actual = @(Get-ChildItem -LiteralPath $AgentsPath -Filter '*.toml' -File -ErrorAction Stop |
            ForEach-Object { $_.Name } |
            Sort-Object)

        Assert-SequenceEqual $actual @($expected | Sort-Object)
    }

    It 'требует согласования, русского языка, качества и контролируемых абстракций' {
        $rules = Get-Content -LiteralPath $GlobalRulesPath -Encoding UTF8 -Raw -ErrorAction Stop

        foreach ($requiredText in @(
            'явного утверждения пользователя',
            'Основной язык документации — русский',
            'Качество первично',
            '500 строк',
            'утверждённых ТЗ, roadmap или ADR',
            'status-файл и активный план',
            'утверждённые стек и архитектуру',
            'фактические проверки, риски и отклонения',
            'Независимые задачи можно выполнять параллельно',
            'пересекающееся владение файлами'
        )) {
            Assert-TextContains $rules $requiredText
        }
    }

    It 'требует согласования интеграции и сохраняет границы делегирования' {
        $rules = Get-Content -LiteralPath $GlobalRulesPath -Encoding UTF8 -Raw -ErrorAction Stop

        foreach ($requiredText in @(
            'явного утверждения пользователя перед интеграцией или слиянием существенных изменений',
            'Главный агент может делегировать работу в рамках утверждённого этапа',
            'матрице ролей',
            'Субагент не создаёт дальнейших субагентов без явного разрешения'
        )) {
            Assert-TextContains $rules $requiredText
        }
    }

    It 'требует русское сопровождение обязательного английского публичного документа' {
        $rules = Get-Content -LiteralPath $GlobalRulesPath -Encoding UTF8 -Raw -ErrorAction Stop

        foreach ($requiredText in @(
            'публичный или внешний документ необходимо вести на английском',
            'русское резюме, русский комментарий или связанная русская версия'
        )) {
            Assert-TextContains $rules $requiredText
        }
    }

    It 'каждая роль содержит обязательные поля и процессные обязанности' {
        $files = @(Get-ChildItem -LiteralPath $AgentsPath -Filter '*.toml' -File -ErrorAction Stop)
        foreach ($file in $files) {
            $role = Get-RoleToml -Path $file.FullName
            foreach ($field in @('name', 'description', 'developer_instructions')) {
                if (-not $role.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($role[$field])) {
                    throw "Роль '$($file.Name)' не содержит непустое поле '$field'."
                }
            }

            $expectedKeys = @('description', 'developer_instructions', 'name')
            if ($file.BaseName -in @('ux_researcher', 'ui_designer', 'backend_architect', 'debugger', 'code_reviewer')) {
                $expectedKeys += 'sandbox_mode'
            }
            Assert-SequenceEqual @($role.Keys | Sort-Object) @($expectedKeys | Sort-Object)

            foreach ($requiredText in @(
                'status-файл и активный план',
                'владение файлами',
                'утверждённые стек и архитектуру',
                'на русском',
                'фактические проверки, риски и отклонения'
            )) {
                Assert-TextContains $role['developer_instructions'] $requiredText
            }
        }
    }

    It 'исследовательские, архитектурные, диагностические и review-роли read-only' {
        foreach ($roleName in @('ux_researcher', 'ui_designer', 'backend_architect', 'debugger', 'code_reviewer')) {
            $role = Get-RoleToml -Path (Join-Path $AgentsPath "$roleName.toml")
            Assert-Equal $role['sandbox_mode'] 'read-only'
        }
    }

    It 'роли реализации не получают read-only режим' {
        foreach ($roleName in @('frontend_developer', 'android_developer', 'ios_developer', 'dotnet_maui_developer')) {
            $role = Get-RoleToml -Path (Join-Path $AgentsPath "$roleName.toml")
            if ($role.ContainsKey('sandbox_mode') -and $role['sandbox_mode'] -eq 'read-only') {
                throw "Роль реализации '$roleName' ошибочно объявлена read-only."
            }
        }
    }

    It 'содержит профессиональные контракты для ключевых ролей' {
        $requiredMarkersByRole = @{
            'android_developer' = @('Kotlin', 'Jetpack Compose', 'lifecycle', 'восстановление состояния', 'разрешения', 'coroutines', 'конкурентность', 'accessibility', 'тесты', 'производительность', 'готовность к релизу')
            'ios_developer' = @('Swift', 'SwiftUI', 'UIKit', 'lifecycle', 'восстановление состояния', 'разрешения', 'privacy', 'Swift concurrency', 'accessibility', 'тесты', 'производительность', 'App Store')
            'dotnet_maui_developer' = @('C#', 'XAML', 'интеграций Android и iOS', 'lifecycle', 'восстановление состояния', 'разрешения', 'async', 'отмен', 'accessibility', 'тесты', 'macOS/Xcode', 'непроверенные утверждения')
            'frontend_developer' = @('семантический HTML', 'accessibility', 'адаптивные состояния', 'клавиатур', 'фокус', 'состояние клиента', 'получение данных', 'состояния ошибок', 'производительность', 'тесты')
            'backend_architect' = @('границ', 'API', 'данн', 'аутентификац', 'безопасност', 'транзакц', 'конкурентн', 'идемпотентн', 'масштабирован', 'наблюдаемост', 'миграци', 'откат', 'артефакты проектирования', 'без изменения реализации')
            'code_reviewer' = @('корректность', 'безопасность', 'регрессии', 'недостающие тесты', 'серьёзность', 'файл и строка', 'триггер', 'влияние', 'направление исправления', 'проверенные факты', 'предположения', 'без внесения изменений')
        }

        foreach ($roleName in $requiredMarkersByRole.Keys) {
            $role = Get-RoleToml -Path (Join-Path $AgentsPath "$roleName.toml")
            foreach ($marker in $requiredMarkersByRole[$roleName]) {
                Assert-TextContains $role['developer_instructions'] $marker
            }
        }
    }
}

Describe 'Базовые шаблоны проектной документации' {
    It 'содержит полный ожидаемый набор управляемых шаблонов' {
        $expected = @(
            'AGENTS.md',
            '.codex/governance/README.md',
            'docs/product/vision.md',
            'docs/product/scope.md',
            'docs/product/roadmap.md',
            'docs/requirements/functional.md',
            'docs/requirements/non-functional.md',
            'docs/requirements/backlog.md',
            'docs/architecture/overview.md',
            'docs/architecture/technology-stack.md',
            'docs/architecture/data-model.md',
            'docs/architecture/integrations.md',
            'docs/architecture/decisions/ADR-template.md',
            'docs/plans/templates/active-plan.md',
            'docs/plans/templates/agent-task.md',
            'docs/plans/templates/migration-analysis.md',
            'docs/quality/quality-gates.md',
            'docs/quality/test-strategy.md',
            'docs/quality/security.md',
            'docs/operations/deployment.md',
            'docs/operations/observability.md',
            'docs/operations/backup-and-recovery.md',
            'docs/operations/incident-response.md',
            'docs/status/current.md',
            'docs/status/changelog.md'
        )

        $actual = @(Get-ManagedTemplates | ForEach-Object {
            $_.FullName.Substring($BaseTemplatesPath.Length).TrimStart([char]'\', [char]'/').Replace('\', '/')
        })

        Assert-SequenceEqual $actual @($expected | Sort-Object)
    }

    It 'каждый управляемый Markdown-шаблон начинается с YAML-метаданных и Draft' {
        foreach ($file in Get-ManagedTemplates) {
            $content = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw -ErrorAction Stop
            Assert-TextMatches $content '^---\r?\n'
            Assert-TextContains $content 'status: Draft'
            Assert-TextContains $content 'owner:'
            Assert-TextContains $content 'created:'
            Assert-TextContains $content 'updated:'
            Assert-TextContains $content 'related:'
        }
    }

    It 'использует только разрешённые токены и не содержит абсолютных путей компьютера' {
        $allowedTokens = @(
            '{{PROJECT_NAME}}',
            '{{DATE}}',
            '{{RULES_VERSION}}',
            '{{RULES_COMMIT}}',
            '{{CONTENT_HASH}}',
            '{{OVERLAYS_JSON}}'
        )

        foreach ($file in Get-ManagedTemplates) {
            $content = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw -ErrorAction Stop
            foreach ($match in [regex]::Matches($content, '\{\{[^}]+\}\}')) {
                if ($allowedTokens -notcontains $match.Value) {
                    throw "В '$($file.FullName)' используется неразрешённый токен '$($match.Value)'."
                }
            }

            Assert-TextNotMatches $content '(?im)(?:^[A-Z]:\\|/Users/|/home/|C:\\Users\\)'
        }
    }

    It 'current status содержит обязательную точку восстановления контекста' {
        $content = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/status/current.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($section in @('Продукт', 'Утверждённый стек', 'Milestone', 'Активный план', 'Завершённое', 'Выполняемое', 'Ожидающие решения', 'Риски', 'Фактические проверки', 'Следующий шаг', 'Обязательное чтение')) {
            Assert-TextContains $content $section
        }
    }

    It 'шаблон активного плана содержит управляемые границы этапа' {
        $content = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/plans/templates/active-plan.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($section in @('Цель', 'Требования', 'Scope', 'Владение', 'Шаги', 'Критерии приёмки', 'Команды и проверки', 'Риски', 'Зависимости', 'Журнал отклонений и решений')) {
            Assert-TextContains $content $section
        }
    }

    It 'ADR-template фиксирует основания решения и условия пересмотра' {
        $content = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/architecture/decisions/ADR-template.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($section in @('Контекст', 'Варианты', 'Решение', 'Последствия', 'Условия пересмотра', 'утверждённые ТЗ, roadmap или ADR')) {
            Assert-TextContains $content $section
        }
    }

    It 'roadmap разрешает реализацию только для Now' {
        $content = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/product/roadmap.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($section in @('Now', 'Next', 'Later', 'Not planned', 'Только элементы Now разрешают реализацию')) {
            Assert-TextContains $content $section
        }
    }

    It 'шаблоны требований задают стабильные идентификаторы, приоритеты и исключения' {
        $functional = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/requirements/functional.md') -Encoding UTF8 -Raw -ErrorAction Stop
        $nonFunctional = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/requirements/non-functional.md') -Encoding UTF8 -Raw -ErrorAction Stop

        foreach ($marker in @('FR-', 'UX-', 'Формулировка', 'Критерии приёмки', 'Источник', 'Статус', 'Ссылки', 'Явные исключения', 'Must', 'Should', 'Could', "Won't now")) {
            Assert-TextContains $functional $marker
        }

        foreach ($marker in @('NFR-', 'SEC-', 'ACC-', 'OPS-', 'Метрика', 'Метод проверки', 'Источник', 'Статус', 'Ссылки', 'Явные исключения', 'Must', 'Should', 'Could', "Won't now")) {
            Assert-TextContains $nonFunctional $marker
        }
    }

    It 'Markdown-таблицы требований имеют одинаковое число колонок' {
        foreach ($path in @(
            (Join-Path $BaseTemplatesPath 'docs/requirements/functional.md'),
            (Join-Path $BaseTemplatesPath 'docs/requirements/non-functional.md')
        )) {
            Assert-MarkdownTablesHaveMatchingColumnCounts -Path $path
        }
    }

    It 'базовый AGENTS указывает источники истины, команды и Definition of Done' {
        $content = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'AGENTS.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('Карта документации и источников истины', 'docs/status/current.md', 'docs/plans/active/', 'docs/requirements/', 'docs/architecture/decisions/', 'Утверждённый активный план', 'выбранный overlay', 'документация проекта', 'docs/quality/quality-gates.md')) {
            Assert-TextContains $content $marker
        }
    }

    It 'quality gates содержит полный Definition of Done' {
        $content = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/quality/quality-gates.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('Definition of Done', 'критерии приёмки выполнены', 'утверждённым требованиям, стеку и архитектуре', 'сборка и необходимые проверки фактически прошли', 'нет необъяснённых ошибок и предупреждений', 'критичные замечания review закрыты', 'безопасность и доступность проверены соразмерно риску', 'документация и `docs/status/current.md` обновлены', 'ограничения и отклонения перечислены', 'пользователь принял результат')) {
            Assert-TextContains $content $marker
        }
    }

    It 'technology stack сохраняет доказательства и решение пользователя' {
        $content = Get-Content -LiteralPath (Join-Path $BaseTemplatesPath 'docs/architecture/technology-stack.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('Дата проверки', 'Официальные источники', 'Поддержка', 'Зрелость', 'Производительность', 'Безопасность', 'Стоимость сопровождения', 'Инструменты', 'Минимум два жизнеспособных варианта', 'Сравнение вариантов', 'Рекомендация', 'Ограничения', 'Решение пользователя', 'Preview и experimental API', 'прототипах или через отдельный ADR')) {
            Assert-TextContains $content $marker
        }
    }
}

Describe 'Платформенные overlays' {
    It 'содержит ровно пять ожидаемых overlays с двумя файлами в каждом' {
        $expected = @('android', 'dotnet', 'dotnet-maui', 'ios', 'web')
        $actual = @(Get-ChildItem -LiteralPath $OverlaysPath -Directory -ErrorAction Stop |
            ForEach-Object { $_.Name } |
            Sort-Object)

        Assert-OrdinalSequenceEqual -Actual $actual -Expected $expected

        foreach ($name in $expected) {
            $directory = Join-Path $OverlaysPath $name
            $files = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction Stop |
                ForEach-Object { $_.Name } |
                Sort-Object)
            Assert-OrdinalSequenceEqual -Actual $files -Expected @('AGENTS.append.md', 'overlay.json')
        }
    }

    It 'строго разбирает переносимые manifests и проверяет их контракт' {
        $expectedNames = @('android', 'dotnet', 'dotnet-maui', 'ios', 'web')
        $semVerPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'

        $manifests = @(Get-OverlayManifests)
        Assert-OrdinalSequenceEqual -Actual @($manifests | ForEach-Object { $_.Directory.Name }) -Expected $expectedNames

        foreach ($entry in $manifests) {
            $manifest = $entry.Value
            $properties = @($manifest.PSObject.Properties.Name | Sort-Object)
            Assert-OrdinalSequenceEqual -Actual $properties -Expected @('displayName', 'name', 'requiredTools', 'targetDirectories', 'verificationCommands', 'version')

            if ($manifest.name -isnot [string] -or -not [System.StringComparer]::Ordinal.Equals($manifest.name, $entry.Directory.Name)) {
                throw "Manifest '$($entry.Path)' должен содержать name, равное имени каталога."
            }
            if ($manifest.displayName -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.displayName)) {
                throw "Manifest '$($entry.Path)' должен содержать непустое displayName."
            }
            if ($manifest.version -isnot [string] -or $manifest.version -notmatch $semVerPattern) {
                throw "Manifest '$($entry.Path)' должен содержать строгую SemVer-версию overlay."
            }

            foreach ($arrayProperty in @('targetDirectories', 'requiredTools', 'verificationCommands')) {
                $value = $manifest.$arrayProperty
                if ($value -isnot [System.Array] -or $value.Count -eq 0) {
                    throw "Manifest '$($entry.Path)' должен содержать непустой массив $arrayProperty."
                }
                foreach ($item in $value) {
                    if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
                        throw "Manifest '$($entry.Path)' содержит недопустимый элемент $arrayProperty."
                    }
                }
            }

            foreach ($targetDirectory in $manifest.targetDirectories) {
                Assert-SafeOverlayTargetDirectory -Path $targetDirectory
            }
            foreach ($tool in $manifest.requiredTools) {
                if ($tool -notmatch '^[a-z][a-z0-9-]*$') {
                    throw "Логическое имя инструмента '$tool' в '$($entry.Path)' недопустимо."
                }
            }
        }
    }

    It 'не фиксирует версии SDK или runtime в manifests' {
        foreach ($entry in Get-OverlayManifests) {
            $content = Get-Content -LiteralPath $entry.Path -Encoding UTF8 -Raw -ErrorAction Stop
            Assert-TextNotMatches $content '(?im)\b(?:sdk|runtime|dotnet|node(?:js)?|kotlin|swift|gradle|xcode)\s*(?:version\s*)?\d+(?:\.\d+){0,3}\b'
        }
    }

    It 'задаёт для всех overlays исполнимые команды или документированные шаблоны' {
        $expectedCommands = @{
            'android' = @('./gradlew {{GRADLE_TASK}}', '.\gradlew.bat {{GRADLE_TASK}}')
            'dotnet' = @('dotnet restore', 'dotnet build', 'dotnet test')
            'dotnet-maui' = @('dotnet workload restore', 'dotnet build -f {{DOTNET_MAUI_TARGET}}')
            'ios' = @('xcodebuild {{XCODEBUILD_ARGUMENTS}}')
            'web' = @('{{PACKAGE_MANAGER}} run {{SCRIPT}}')
        }
        $expectedPlaceholders = @{
            'android' = @('{{GRADLE_TASK}}')
            'dotnet' = @()
            'dotnet-maui' = @('{{DOTNET_MAUI_TARGET}}')
            'ios' = @('{{XCODEBUILD_ARGUMENTS}}')
            'web' = @('{{PACKAGE_MANAGER}}', '{{SCRIPT}}')
        }

        foreach ($entry in Get-OverlayManifests) {
            $overlayName = $entry.Directory.Name
            Assert-OrdinalSequenceEqual -Actual @($entry.Value.verificationCommands) -Expected $expectedCommands[$overlayName]

            $commandText = [string]::Join("`n", @($entry.Value.verificationCommands))
            Assert-TextNotMatches $commandText '<[^>]+>'
            $actualPlaceholders = @([regex]::Matches($commandText, '\{\{[A-Z][A-Z0-9_]*\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique)
            Assert-OrdinalSequenceEqual -Actual $actualPlaceholders -Expected $expectedPlaceholders[$overlayName]

            if ($actualPlaceholders.Count -gt 0) {
                $appendPath = Join-Path $entry.Directory.FullName 'AGENTS.append.md'
                $append = Get-Content -LiteralPath $appendPath -Encoding UTF8 -Raw -ErrorAction Stop
                foreach ($marker in @('Единое соглашение для placeholders', 'только из утверждённого', 'Неразрешённый placeholder означает ошибку', 'нельзя выполнять')) {
                    Assert-TextContains $append $marker
                }
                foreach ($placeholder in $actualPlaceholders) {
                    Assert-TextContains $append $placeholder.Trim([char]'{' , [char]'}')
                }
            }
        }
    }

    It 'каждый append-файл остаётся русскоязычным дополнением и требует чтения источников истины' {
        foreach ($entry in Get-OverlayManifests) {
            $appendPath = Join-Path $entry.Directory.FullName 'AGENTS.append.md'
            $content = Get-Content -LiteralPath $appendPath -Encoding UTF8 -Raw -ErrorAction Stop

            Assert-TextMatches $content '^---\r?\n'
            foreach ($marker in @('status: Draft', 'дополняют глобальные правила', 'не отменяют глобальные правила', 'docs/architecture/technology-stack.md', 'активный план', 'docs/status/current.md', 'Не угадывайте', 'production dependency', 'ADR')) {
                Assert-TextContains $content $marker
            }
            foreach ($match in [regex]::Matches($content, '\{\{[^}]+\}\}')) {
                if ($match.Value -notin @('{{PROJECT_NAME}}', '{{DATE}}', '{{RULES_VERSION}}', '{{RULES_COMMIT}}', '{{CONTENT_HASH}}', '{{OVERLAYS_JSON}}')) {
                    throw "В '$appendPath' используется неразрешённый токен '$($match.Value)'."
                }
            }
        }
    }

    It 'dotnet overlay задаёт безопасные базовые проверки' {
        $entry = @(Get-OverlayManifests | Where-Object { $_.Directory.Name -ceq 'dotnet' })[0]
        Assert-OrdinalSequenceEqual -Actual @($entry.Value.verificationCommands) -Expected @('dotnet restore', 'dotnet build', 'dotnet test')
        $content = Get-Content -LiteralPath (Join-Path $entry.Directory.FullName 'AGENTS.append.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('nullable', 'async', 'cancellation', 'dependency', 'security', 'platform-specific')) {
            Assert-TextContains $content $marker
        }
    }

    It 'web overlay не угадывает package manager и охватывает качество интерфейса' {
        $entry = @(Get-OverlayManifests | Where-Object { $_.Directory.Name -ceq 'web' })[0]
        $manifestText = Get-Content -LiteralPath $entry.Path -Encoding UTF8 -Raw -ErrorAction Stop
        Assert-TextNotMatches $manifestText '(?i)\b(?:npm|pnpm|yarn|bun)\b'
        $content = Get-Content -LiteralPath (Join-Path $entry.Directory.FullName 'AGENTS.append.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('package manager', 'lockfile', 'scripts', 'Не угадывайте npm, pnpm, yarn или bun', 'build', 'test', 'lint', 'typecheck', 'accessibility', 'адаптив', 'клавиатур', 'фокус', 'производительность')) {
            Assert-TextContains $content $marker
        }
    }

    It 'android overlay требует только Gradle wrapper проекта' {
        $entry = @(Get-OverlayManifests | Where-Object { $_.Directory.Name -ceq 'android' })[0]
        $content = Get-Content -LiteralPath (Join-Path $entry.Directory.FullName 'AGENTS.append.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('gradlew', 'gradlew.bat', 'POSIX', 'Windows', 'не системный Gradle', 'Kotlin', 'Jetpack Compose', 'lifecycle', 'восстановление состояния', 'разрешения', 'coroutines', 'accessibility', 'emulator')) {
            Assert-TextContains $content $marker
        }
    }

    It 'ios overlay соблюдает границу macOS и не угадывает параметры xcodebuild' {
        $entry = @(Get-OverlayManifests | Where-Object { $_.Directory.Name -ceq 'ios' })[0]
        $content = Get-Content -LiteralPath (Join-Path $entry.Directory.FullName 'AGENTS.append.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('xcodebuild', 'macOS', 'Xcode', 'scheme', 'workspace', 'destination', 'Swift', 'SwiftUI', 'concurrency', 'privacy', 'разрешения', 'accessibility', 'Windows', 'нельзя заявлять')) {
            Assert-TextContains $content $marker
        }
    }

    It 'dotnet maui overlay задаёт target-specific проверку и границу iOS' {
        $entry = @(Get-OverlayManifests | Where-Object { $_.Directory.Name -ceq 'dotnet-maui' })[0]
        $content = Get-Content -LiteralPath (Join-Path $entry.Directory.FullName 'AGENTS.append.md') -Encoding UTF8 -Raw -ErrorAction Stop
        foreach ($marker in @('dotnet workload restore', 'target-specific', 'target framework', 'shared', 'platform', 'lifecycle', 'восстановление состояния', 'разрешения', 'async', 'cancellation', 'accessibility', 'macOS', 'Xcode')) {
            Assert-TextContains $content $marker
        }
    }

    It 'dotnet maui подставляет TFM после ключа -f' {
        $entry = @(Get-OverlayManifests | Where-Object { $_.Directory.Name -ceq 'dotnet-maui' })[0]
        $template = @($entry.Value.verificationCommands | Where-Object { $_ -match 'DOTNET_MAUI_TARGET' })[0]
        $command = $template.Replace('{{DOTNET_MAUI_TARGET}}', 'net9.0-android')

        Assert-Equal $command 'dotnet build -f net9.0-android'
        Assert-TextMatches $command '^dotnet build -f net9\.0-android$'
    }
}
