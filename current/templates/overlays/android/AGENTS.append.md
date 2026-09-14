---
status: Draft
---

# Дополнение для Android

Эти правила дополняют глобальные правила и не отменяют глобальные правила.

До начала работы прочитайте утверждённые `docs/architecture/technology-stack.md`, активный план и `docs/status/current.md`. Не угадывайте структуру Android-проекта, версии SDK, Gradle-задачи или параметры запуска.

- Используйте только Gradle wrapper проекта: `gradlew` или `gradlew.bat`; не системный Gradle.
- Для Kotlin и Jetpack Compose проверяйте lifecycle, восстановление состояния, разрешения, coroutines и accessibility.
- При релевантности подтверждайте сценарии на emulator или устройстве; не выдавайте непроверенные результаты за фактическую проверку.
- Любая production dependency, preview/experimental API или изменение стека требует анализа, утверждения пользователя и ADR согласно глобальным правилам.
