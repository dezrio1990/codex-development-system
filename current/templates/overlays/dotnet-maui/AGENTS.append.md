---
status: Draft
---

# Дополнение для .NET MAUI

Эти правила дополняют глобальные правила и не отменяют глобальные правила.

До начала работы прочитайте утверждённые `docs/architecture/technology-stack.md`, активный план и `docs/status/current.md`. Не угадывайте структуру MAUI-проекта, версии SDK, workload, target-specific target или команды.

- Выполняйте `dotnet workload restore` и target-specific build только для target из утверждённого стека.
- Единое соглашение для placeholders: маркер в двух фигурных скобках с именем в верхнем регистре заменяется только из утверждённого `technology-stack.md` и проверяемых файлов проекта. Имя `DOTNET_MAUI_TARGET` означает утверждённый target-specific target. Неразрешённый placeholder означает ошибку; такую команду нельзя выполнять.
- Сохраняйте границы shared-кода и platform-кода; проверяйте lifecycle, восстановление состояния, разрешения, async/cancellation и accessibility.
- Фактическая iOS verification допустима только на macOS с Xcode; в иной среде фиксируйте ограничение, а не заявляйте выполнение.
- Любая production dependency, preview/experimental API или изменение стека требует анализа, утверждения пользователя и ADR согласно глобальным правилам.
