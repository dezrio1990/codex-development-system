# Codex Development System Lite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Превратить текущий репозиторий в простой русскоязычный набор версионируемых правил, ролей и шаблонов без исполняемой инфраструктуры.

**Architecture:** `current/` хранит редактируемую редакцию, а `versions/1.0/` — утверждённый неизменяемый снимок. Проекты закрепляют версию в `.codex/codex-rules.json` и получают локальную копию документов через обычную работу Codex; Git обеспечивает историю, сравнение и откат.

**Tech Stack:** Markdown, JSON, Git. PowerShell-скрипты, собственные валидаторы, schemas, hashes и CI для документации не используются.

**Spec:** `docs/superpowers/specs/2026-09-14-codex-development-system-lite-design.md`

## Global Constraints

- Вся пользовательская документация ведётся на русском языке либо содержит русское пояснение.
- Архитектура, стек и существенные этапы проектов согласовываются с пользователем до реализации.
- `versions/<номер>/` не редактируется после выпуска; исправления получают новый номер.
- Проект может бессрочно оставаться на закреплённой версии.
- Обновление проекта выполняется только после анализа различий и явного согласования.
- Репозиторий не содержит исполняемых средств установки, синхронизации, публикации или валидации правил.
- Публикация на GitHub и перенос в `D:\Projects\codex-development-system` не входят в этот план.

---

### Task 1: Перевести репозиторий на структуру Lite

**Files:**

- Modify: `AGENTS.md`
- Rewrite: `README.md`
- Rewrite: `CHANGELOG.md`
- Create: `examples/codex-rules.json`
- Create: `current/rules/base.md`
- Create: `current/roles/*.md`
- Preserve and relocate: `current/templates/base/**`, `current/templates/overlays/**`
- Create snapshot: `versions/1.0/rules/**`, `versions/1.0/roles/**`, `versions/1.0/templates/**`, `versions/1.0/VERSION.md`
- Preserve: `docs/superpowers/specs/2026-09-14-codex-development-system-lite-design.md`
- Delete: `current/global/**`
- Delete: `current/scripts/**`
- Delete: `tests/**`
- Delete: `schemas/**`
- Delete: `migrations/**`
- Delete: `support.json`
- Delete: `VERSION`
- Delete: `docs/superpowers/specs/2026-09-14-codex-development-system-design.md`
- Delete: `docs/superpowers/plans/2026-09-14-codex-development-system-v1-plan.md`

**Interfaces:**

- Consumes: утверждённые правила из `current/global/AGENTS.md`, инструкции девяти ролей из `current/global/agents/*.toml`, базовые шаблоны и пять технологических overlays.
- Produces: читаемый человеком выпуск `versions/1.0/` и пример проектной привязки с полями `source`, `version`, `profiles`.

- [ ] **Step 1: Зафиксировать исходный состав полезного контента**

Проверить, что перед очисткой существуют:

```text
current/global/AGENTS.md
current/global/agents/android_developer.toml
current/global/agents/backend_architect.toml
current/global/agents/code_reviewer.toml
current/global/agents/debugger.toml
current/global/agents/dotnet_maui_developer.toml
current/global/agents/frontend_developer.toml
current/global/agents/ios_developer.toml
current/global/agents/ui_designer.toml
current/global/agents/ux_researcher.toml
current/templates/base/AGENTS.md
current/templates/overlays/android/AGENTS.append.md
current/templates/overlays/dotnet/AGENTS.append.md
current/templates/overlays/dotnet-maui/AGENTS.append.md
current/templates/overlays/ios/AGENTS.append.md
current/templates/overlays/web/AGENTS.append.md
```

Run:

```powershell
rg --files current/global current/templates | Sort-Object
```

Expected: перечислены глобальные правила, девять ролей, базовые шаблоны и пять overlays.

- [ ] **Step 2: Создать человекочитаемые правила и роли в `current/`**

Перенести содержание `current/global/AGENTS.md` в `current/rules/base.md`. Для каждого TOML-профиля создать одноимённый Markdown-файл в `current/roles/`, сохранив его содержательные инструкции без служебной TOML-обвязки.

Каждый файл роли должен содержать:

```markdown
# <Название роли>

## Назначение
<когда подключать роль>

## Ответственность
<что роль должна выполнить>

## Ограничения
<read-only или разрешённая область изменений>

## Результат
<ожидаемый формат передачи результата основному агенту>
```

Не сокращать утверждённые профессиональные требования ролей.

- [ ] **Step 3: Сохранить шаблоны и удалить исполняемую инфраструктуру**

Оставить содержимое `current/templates/base/**` и `current/templates/overlays/**`. Удалить `current/global`, `current/scripts`, `tests`, `schemas`, `migrations`, `support.json`, корневой `VERSION`, старую спецификацию и старый план.

Expected: в `current/` остаются только `rules/`, `roles/` и `templates/`.

- [ ] **Step 4: Создать пример привязки проекта**

Создать `examples/codex-rules.json` с точным содержанием:

```json
{
  "source": "https://github.com/dezrio1990/codex-development-system",
  "version": "1.0",
  "profiles": [
    "base",
    "dotnet"
  ]
}
```

В README пояснить допустимые профили: `base`, `dotnet`, `web`, `android`, `ios`, `dotnet-maui`.

- [ ] **Step 5: Переписать корневой `AGENTS.md`**

Оставить только короткие правила работы с этим репозиторием:

```markdown
# Codex Development System

- Пользователь утверждает архитектуру, стек и план до существенной реализации.
- Рабочая редакция находится в `current/`; опубликованные версии — в `versions/`.
- Папки опубликованных версий неизменяемы.
- Документация ведётся на русском языке или сопровождается русским пояснением.
- Субагенты подключаются только когда специализация существенно улучшает качество или скорость.
- Исполняемый код приложения проверяется тестами и code review; изменения документации проходят один содержательный просмотр.
- Новая версия и обновление проекта требуют явного согласования пользователя.
```

- [ ] **Step 6: Создать подробный русский `README.md`**

README должен последовательно объяснять:

1. назначение репозитория;
2. различие `current/` и `versions/`;
3. доступные профили;
4. создание нового проекта;
5. добавление `.codex/codex-rules.json`;
6. копирование выбранных правил в `.codex/rules/`;
7. передачу правил основному Codex и субагентам;
8. работу проекта на старой версии;
9. анализ и согласование обновления;
10. выпуск новой версии правил;
11. примеры готовых запросов пользователю к Codex;
12. отсутствие необходимости запускать PowerShell.

Включить готовый сценарий нового проекта:

```text
Создай новый проект <название>. Используй Codex Development System версии 1.0
и профили base, <профиль>. Сначала прочитай закреплённые правила, затем предложи
архитектуру, стек и этапы. Не начинай существенную реализацию до моего утверждения.
```

- [ ] **Step 7: Создать выпуск `versions/1.0/`**

Побайтно скопировать утверждённые `current/rules`, `current/roles` и `current/templates` в `versions/1.0/`. Создать `versions/1.0/VERSION.md`:

```markdown
# Версия 1.0

Статус: утверждена  
Дата выпуска: 2026-09-14

Первый выпуск упрощённой системы: базовые правила, девять ролей, проектные шаблоны и профили .NET, Web, Android, iOS и .NET MAUI.
```

- [ ] **Step 8: Переписать `CHANGELOG.md`**

Зафиксировать выпуск `1.0` и отдельно указать, что прежняя исполняемая инфраструктура удалена как несоразмерная назначению репозитория. Не описывать удалённые PowerShell-функции как поддерживаемый интерфейс.

- [ ] **Step 9: Выполнить одну содержательную проверку**

Run:

```powershell
git diff --check
rg --files current versions/1.0 examples | Sort-Object
rg -n "TestHarness|Install-GlobalRules|Initialize-ProjectRules|Sync-ProjectRules|Test-ProjectRules|checksums|releaseContentHash" AGENTS.md README.md CHANGELOG.md current versions/1.0 examples
git status --short
```

Expected:

- `git diff --check` не сообщает ошибок;
- `current/` и `versions/1.0/` содержат rules, roles и templates;
- поиск старой инфраструктуры не возвращает ссылок в продуктовой документации;
- список изменений не содержит случайных файлов вне заявленного scope.

Вручную проверить, что в README есть полный сценарий нового проекта, обновление версии и готовые запросы к Codex. Программные тесты и проверки PowerShell 5.1 не запускать.

- [ ] **Step 10: Провести один read-only содержательный review**

Ревьюер проверяет только:

- сохранность утверждённых правил и девяти ролей;
- понятность README для первого использования;
- совпадение `current/` и `versions/1.0/`;
- отсутствие ссылок на удалённую автоматику;
- русскоязычность и непротиворечивость документов.

Исправить только Critical/Important замечания одним циклом. Повторное многоступенчатое ревью документации не выполнять.

- [ ] **Step 11: Создать один cleanup-коммит**

```powershell
git add -A
git commit -m "refactor: simplify development system to documentation"
```

Expected: один логический коммит переводит репозиторий на Lite; GitHub push, tag и перенос каталога не выполняются.
