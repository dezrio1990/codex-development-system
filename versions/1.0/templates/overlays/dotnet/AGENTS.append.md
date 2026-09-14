---
status: Draft
---

# Дополнение для .NET

Эти правила дополняют глобальные правила и не отменяют глобальные правила.

До начала работы прочитайте утверждённые `docs/architecture/technology-stack.md`, активный план и `docs/status/current.md`. Не угадывайте структуру решения, версии SDK, параметры проектов или команды, отсутствующие в утверждённом стеке и репозитории.

- Выполняйте `dotnet restore`, `dotnet build` и `dotnet test` только для утверждённых проектов, solution или platform-specific targets.
- Учитывайте nullable-аннотации, async/cancellation, границы зависимостей и security-последствия изменений.
- Любая production dependency, preview/experimental API или изменение стека требует анализа, утверждения пользователя и ADR согласно глобальным правилам.
