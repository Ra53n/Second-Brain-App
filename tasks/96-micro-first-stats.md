# Задача 96: строка «Micro-first» в статистике сессии чата тюнинга

## Тип

фича (малая: вычисляемая статистика + одна строка UI, персистентных полей нет)

## Модель

Fable 5

## Цель

Панель статистики показывает цифры финальной домашки «День 10» в её терминах:
сколько запросов обработала micro-модель, сколько ушло в fallback, общее количество
вызовов большой LLM, средняя latency micro против каскада — одной строкой «Micro-first»
в блоке «Сессия», без вычислений в уме из чипов эскалации.

## Допущения и corner-кейсы

- «Обработала micro» — показанный ответ от дешёвой ступени: эскалации не было
  (nil/unavailable) ЛИБО сильная вызывалась, но её ответ не показан
  (failed/notImproved). «Ушло в fallback» — сильная ВЫЗЫВАЛАСЬ
  (succeeded/notImproved/failed). Определения зафиксированы doc-комментариями.
- «Вызовов большой LLM» — сумма totalCalls сильной ступени: succeeded → показанный
  отчёт; notImproved → strongReport; failed → 1 (вызов был, отчёта нет).
- Latency: разрез по факту вызова сильной (полная стоимость fullMetrics); nil при
  пустой группе.
- Строка показывается всегда при answered > 0 («fallback 0» при выключенной
  эскалации — тоже результат замера). Батч, VM, пайплайн не тронуты.

## Архитектура

`TuningChatSessionStats` + `microAnsweredCount`, `fallbackAttemptedCount`,
`strongCallsTotal`, `avgTotalLatencyMicroOnly?`, `avgTotalLatencyWithFallback?` —
тот же проход пар (report, escalation) + zip с fullMetrics. UI: GridRow «Micro-first»
над «Эскалацией» (`microFirstSessionLine`), AX-value дополнен.

## Объём

`Confidence/TuningChatSessionStats.swift`, `FineTuneChatViews.swift`,
`Tests/SecondBrainTests/TuningChatSessionStatsTests.swift`, `tasks/00-INDEX.md`.

## Вне объёма

Батч; изменение поведения каскада; персистентность; смоук-сценарий (новых контролов
нет, AX-value дополняется в существующей панели).

## Критерии приёмки

1. Строка «Micro-first» в «Сессии»: micro N из M (%), fallback K, вызовов сильной X,
   latency micro → каскад; корректна во всех исходах эскалации (таблица-тест).
2. AX-value панели содержит micro/fallback/вызовы сильной.
3. `./scripts/build.sh`, `./scripts/test.sh` зелёные; ревью GO.

## Отчёт тестов

`TuningChatSessionStatsTests` (+4): таблица исходов (nil/unavailable → micro без
fallback; failed/notImproved → micro-ответ + fallback; succeeded → не micro, fallback);
`strongCallsTotal` с РАЗНЫМИ totalCalls на ступень (3+2+1 — регрессия «захардкоженная
1»); разрез latency по факту вызова сильной; пустые группы → nil. Существующие кейсы
не менялись. Итог `./scripts/test.sh`: **1787 тестов, 0 падений, 1 пропущен**.

## Вердикт ревью

**GO** (reviewer). Блокирующих нет; определения (micro = показанный ответ дешёвой,
fallback = сильная вызывалась) корректны и согласованы с таксономией статусов.
Важное закрыто: тест strongCallsTotal дискриминирует метрики от захардкоженной 1
(параметр strongTotalCalls в фикстуре). Мелочи закрыты: доля micro вынесена в
`microShare` (симметрично escalationShare, P1); оговорка про заниженное среднее
каскада на failed-сообщениях (отчёта сильной нет) — в doc-комментарии.

## Результат

Блок «Сессия» получил строку «Micro-first»: «micro закрыла N из M (P%) · fallback K ·
вызовов сильной LLM X · latency A с → B с» — все четыре метрики финальной домашки
«День 10» видны без вычислений; строка показывается при первом же ответе (fallback 0 —
тоже результат). AX-value панели дополнен. Новые поля `TuningChatSessionStats`
вычисляемые, персистентность не менялась; батч/VM/пайплайн не тронуты.
