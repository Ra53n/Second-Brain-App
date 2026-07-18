# 37 — Автоматизация code review

## Цель
Встроенный пресет-пайплайн «Code Review»: триггер — новый PR (PR-watch из 36), слэш-команда `/review <PR URL>` или ручной запуск; агент читает diff, документацию проекта и тесты, проводит ревью полным FSM-проходом; результат — сообщение в чат и (по подтверждению) комментарий в самом PR.

## Зависимости
35 (FSM-движок), 36 (пайплайны, PR-watch, GitHub-токен), 25 (RAG доков проекта), 21 (git-инструменты), 22 (слэш-команды).

## Контекст
Сценарий пользователя: «создан PR либо ручной запрос → агент подтягивает diff, читает документацию, смотрит тесты → проводит review → отписывает в PR или в чате». Ревью — идеальный кандидат на FSM: план (что смотреть) → выполнение (диф по частям, доки, тесты) → проверка (ничего не пропущено) → финальный вердикт. Постинг в PR — write-операция с чужим видимым эффектом: по умолчанию только после явного подтверждения в UI (правило бэклога №16 о write-инструментах).

## Объём работ
- [x] `Pipelines/CodeReview/GitHubClient.swift`: immutable struct, async/await; `pullRequest(owner:repo:number:)` (метаданные), `diff(...)` (Accept: `application/vnd.github.v3.diff`), `files(...)` (постранично), `postComment(owner:repo:number:body:)` (`POST /repos/{o}/{r}/issues/{n}/comments`); токен из Keychain (`github-token`, для постинга нужен write-scope); `enum GitHubError: LocalizedError` (нет токена/403/404/rate limit — человеческие тексты).
- [x] Парсер PR-ссылки `github.com/{owner}/{repo}/pull/{n}` (+ короткая форма `owner/repo#n`) с тестами.
- [x] `Pipelines/CodeReview/CodeReviewInput.swift`: сборка input — diff с капом размера и чанкованием больших диффов (map-reduce по файлам, паттерн чанкования из MeetingPrompts); `[PROJECT_DOCS]` через RAG доков проекта (25); список затронутых тестов и соседних тестов через git-инструменты (21).
- [x] `Pipelines/CodeReview/CodeReviewPrompts.swift`: промпт ревью со структурой ответа — резюме изменений, риски/баги, замечания `file:line`, покрытие тестами, вердикт (approve / нужны правки); парсер структуры для карточки в чате.
- [x] Пресет: кнопка «Добавить Code Review» в разделе «Пайплайны» создаёт преднастроенный PipelineConfig (trigger prWatch, agentMode fsm, inputTemplate ревью); поля репо редактируемые.
- [x] Слэш-команда `/review <PR URL | owner/repo#n>` в чате — запускает тот же прогон с выводом в текущий чат; `/review` без аргумента — подсказка использования.
- [x] Вывод: итоговое ревью — сообщение в destination-чат; под ним кнопка «Отправить комментарием в PR» (превью текста перед отправкой); настройка пайплайна «постить автоматически» (default выкл).
- [x] Локальный diff: ручной запуск ревью незакоммиченных изменений выбранного репо через `git_diff` (21) — тот же промпт, без постинга в PR.

## Вне объёма
Инлайн-комментарии к конкретным строкам через Review API positions (v1 — один сводный комментарий), GitLab/Bitbucket, авто-approve/request-changes, ревью нескольких PR батчем.

## Критерии приёмки
- Тесты: парсер PR-ссылок (полный URL, короткая форма, мусор); чанкование диффа (малый — целиком, большой — по файлам с лимитом); сборка input (диф + доки + тесты в нужных секциях); декодинг DTO GitHub на JSON-фикстурах; парсер структуры ревью (полный/частичный ответ); слэш-команда (валидный URL → прогон, без аргумента → usage).
- `swift build` и `swift test` зелёные.
- Ручная проверка: `/review <url>` реального PR даёт структурированное ревью в чате; кнопка постит комментарий (виден на GitHub); PR-watch пресета триггерит ревью свежего PR; локальный diff ревьюится без сети.

## Подсказки
- Diff огромного PR не влезет в контекст локальной модели — кап + map-reduce обязателен, лимиты задокументировать.
- `diff_url` из payload PR-watch не требует отдельного запроса метаданных.
- Постинг только после успешного terminal answer FSM — не постить частичные результаты failed-прогона.

## Результат

Выполнено; 864 теста зелёные (+47 новых). Компоненты — в `Sources/SecondBrain/Pipelines/CodeReview/`.

Что сделано:
- **GitHubClient** переехал из PRWatcher.swift в `CodeReview/GitHubClient.swift` (один клиент на 36/37) и расширен: `pullRequest`, `diff(owner:repo:number:)` и `diff(url:)` (Accept `application/vnd.github.v3.diff`; diff_url из payload PR-watch — без запроса метаданных), `postComment` (POST issues/{n}/comments; без токена — `.noToken` до сети). `GitHubError`: человеческие тексты для 401/404/403/429 и «нет токена».
- **PRReference** (`parse`: полный URL с хвостами /files и query, короткая форма owner/repo#n; `firstMatch(in:)` для payload) — он же `ReviewTarget` (Codable) в маркере сообщения.
- **CodeReviewInput** — чистые функции: `splitByFile` (по `diff --git`), `packChunks` (жадная группировка, кап файла 12k с пометкой), `testsSection` (затронутые = Tests/ или *Tests.swift; соседние = FooTests.swift среди trackedFiles), `assemble` ([PR]/[DIFF]/[PROJECT_DOCS]/[TESTS]). Лимиты — документированные константы (порог сжатия 24k, итог ≤30k, тесты ≤4k).
- **CodeReviewPrompts**: жёсткая структура ответа (Резюме/Риски/Замечания `путь:строка`/Покрытие тестами) с маркером **«ИТОГ РЕВЬЮ: APPROVE|НУЖНЫ ПРАВКИ»** — намеренно НЕ «ВЕРДИКТ:», который замаскировал бы parseVerdict validation-фазы FSM (проверено тестом «последний маркер побеждает»); `condensePrompt` map-фазы; `parseVerdict` для бейджа.
- **CodeReviewRunner** — общий раннер трёх точек входа: `prepareInput(reference:)` (метаданные+diff), `prepareInput(prWatchPayload:)` (только diff — метаданные из payload), `prepareLocalInput()` (GitClient.diff по projectRepoPath, без 64k-капа инструмента); condense map-БЕЗ-reduce только при diff > 24k (reduce терял бы file:line); `runReview` (FSM + маркер `reviewTarget` на итоге строго после `.finished`), `post`/`autoPostIfConfigured`.
- **displayText в FSM** (задачи 35 семантика не менялась): параметр `startAgentRun`/`runAgentToCompletion` + поле `AgentTaskContext.displayText`; видимое сообщение и автотайтл — короткие, полный input в `task` (персистится целиком — resume повторяет фазу с тем же входом); снапшот dialogContext вырезает последнее user-сообщение и по displayText.
- **/review** в SlashCommands + диспетчер: пусто → usage, мусор → usage с проблемой, `local` → локальный diff (нет репо/пустой diff → локальный ответ без прогона), ссылка → fetch → FSM. isLoading лочит чат на время fetch, каждая ветка ошибки снимает лок (покрыто тестом с падением сети).
- **Пресет**: `PipelineConfig.preset: PipelinePreset?` + `autoPostReviewComment` (снисходительная миграция: незнакомый пресет → обычный пайплайн); кнопка «Добавить Code Review» в тулбаре раздела; в форме — тумблер автопоста, секция «Промпт» скрыта (input собирает раннер). `PipelineEngine`: weak `reviewRunner`, ветка preset==.codeReview (running-запись ДО подготовки — она сама ходит в сеть/LLM), автопост строго после успешного терминала, его ошибка не портит статус прогона.
- **UI постинга**: маркеры `ChatMessage.reviewTarget`/`reviewPostedAt`; кнопка «Отправить комментарием в PR #N» под итогом ревью → шит-превью с редактируемым текстом (паттерн TitleConfirmationView; без токена — disabled с подсказкой; ошибка постинга остаётся в шите); после успеха — персистентное «Отправлено ✓». Бейдж вердикта (зелёный APPROVE / оранжевый «Нужны правки») вычисляется из content.

Отклонения от плана задачи:
- **files(...) постранично НЕ реализован** — список затронутых файлов тривиально извлекается из diff (`splitByFile`), у постраничного API нет потребителя; зафиксировано комментарием в GitHubClient.swift.
- Секция [TESTS] — только списки путей (не содержимое): FSM-агент с включёнными project tools дочитывает нужные тесты `read_file` сам.
- Payload PR-watch не содержит отдельного запроса метаданных, но diff качается по номеру PR (стабильный API-эндпоинт), а не по «сырой» строке diff_url.

Ручная проверка (живое приложение, Ollama qwen-rag:7b): `/review octocat/Hello-World#10507` — реальный PR с GitHub, FSM дошёл до answer со структурой и «ИТОГ РЕВЬЮ: APPROVE», бейдж APPROVE в ленте, кнопка постинга открывает шит-превью (отправка disabled без write-токена, с подсказкой); `/review local` — 78 КБ незакоммиченного диффа сжались map-фазой до ~12 КБ инпута, ревью без сети и без кнопки постинга; `/review` без аргумента — usage без LLM; кнопка «Добавить Code Review» создаёт пресет (prWatch/fsm/автопост выкл), в его форме секция промпта скрыта. Постинг реального комментария не проверялся — у пользователя нет write-токена в Keychain (путь покрыт тестами на скриптованном транспорте).

Агентам следующих задач:
- Постинг инлайн-комментариев (Review API positions) — бэклог; сводный комментарий шлёт `GitHubClient.postComment`.
- Для новых пресетов пайплайнов паттерн готов: case в `PipelinePreset`, ветка в `PipelineEngine.run`, фабрика в `PipelineConfig`.
