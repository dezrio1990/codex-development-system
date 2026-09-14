$Root = Split-Path -Parent $PSScriptRoot
$GlobalRulesPath = Join-Path $Root 'current/global/AGENTS.md'
$AgentsPath = Join-Path $Root 'current/global/agents'
$BaseTemplatesPath = Join-Path $Root 'current/templates/base'

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
}
