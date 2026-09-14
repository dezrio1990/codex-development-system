---
status: Draft
---

# Дополнение для iOS

Эти правила дополняют глобальные правила и не отменяют глобальные правила.

До начала работы прочитайте утверждённые `docs/architecture/technology-stack.md`, активный план и `docs/status/current.md`. Не угадывайте структуру iOS-проекта, версии SDK, scheme, workspace, destination или параметры xcodebuild.

- Используйте xcodebuild только на macOS с Xcode и только с scheme, workspace и destination из утверждённого проекта.
- Для Swift и SwiftUI проверяйте concurrency, privacy, разрешения и accessibility.
- На Windows нельзя заявлять фактическую iOS build/runtime verification: явно фиксируйте ограничение среды.
- Любая production dependency, preview/experimental API или изменение стека требует анализа, утверждения пользователя и ADR согласно глобальным правилам.
