# finetune — тюн локальных LLM

Тулчейн для дообучения локальных моделей на данных владельца: сборка датасета,
валидация, замер baseline, запуск LoRA-тюна и сравнение результата.

Всё считается на своей машине через `mlx_lm` на Apple Silicon. Облачный тюн
(OpenAI, Anthropic) для проекта закрыт: у Anthropic его нет в публичном API,
OpenAI заблокировал доступ. Формат датасета при этом стандартный — chat-JSONL
`{"messages": [...]}`, тот же, что принимают облачные провайдеры.

## Два датасета

| Каталог | Задача | Примеров | Источник |
|---|---|---|---|
| `data/` + `corpus/` | генерация постов в стиле TG-канала | 50 | 12 постов из Obsidian-vault |
| [`dictation/`](dictation/) | пост-процессор голосового ввода | 1895 | выгрузка Wispr Flow |

Оба живут в одной раскладке: `<каталог>/data/{train,valid}.jsonl` плюс sidecar
`*.meta.jsonl`. Клиент запуска и валидатор работают с любым из них.

## Установка

Системный Python 3.9 не подходит — mlx требует 3.10+. Весь тулчейн запускается
интерпретатором из venv.

```bash
uv venv --python 3.11 finetune/.venv
uv pip install --python finetune/.venv/bin/python -r finetune/requirements.txt
finetune/.venv/bin/python finetune/providers.py   # проверка готовности
```

## Полный цикл (на примере диктовки)

```bash
P=finetune/.venv/bin/python

# 1. Валидация датасета
$P finetune/validate.py finetune/dictation/data/{train,valid}.jsonl \
   --system finetune/dictation/system_prompt.txt --min-assistant 30

# 2. Пороги автопроверок vs эталоны автора
$P finetune/dictation_calibrate.py

# 3. Окружение и модель  (аналог upload file)
$P finetune/train.py --workdir dictation prepare --download \
   --system finetune/dictation/system_prompt.txt --min-assistant 30

# 4. Точка отсчёта: 10 примеров eval через базовую модель без тюна
$P finetune/baseline.py --data dictation/data --out dictation/baseline \
   --count 10 --temperature 0.3

# 5. Запуск тюна        (аналог create job)
$P finetune/train.py --workdir dictation start --iters 600

# 6. Слежение           (аналог poll status)
$P finetune/train.py --workdir dictation poll

# 7. Лучший чекпоинт по val loss вместо финального
$P finetune/train.py --workdir dictation best --install

# 8. Те же промпты с адаптером и сравнение
$P finetune/baseline.py --data dictation/data --adapter dictation/adapters \
   --out dictation/tuned --count 10 --temperature 0.3
$P finetune/evaluate.py --checks dictation --data dictation/data \
   --baseline dictation/baseline --tuned dictation/tuned
```

Для датасета постов: убрать `--workdir dictation`, пути `data/`, `--checks style`.

## Клиент запуска тюна

`train.py` — локальный аналог связки «upload file → create job → poll status»:

| Команда | Что делает |
|---|---|
| `prepare` | ищет интерпретатор с mlx-lm, гоняет валидатор по train/valid, проверяет модель в кэше, при `--download` качает |
| `start` | запускает `mlx_lm.lora --train` отдельной сессией, пишет `runs/run.json` (pid, конфиг) и `runs/train.log` |
| `poll` | разбирает лог, печатает `iter N/M, train loss, val loss, ETA`, ждёт конца, код выхода по результату |
| `status` / `logs` / `stop` | снимок, хвост лога, остановка (SIGTERM → SIGKILL) |
| `best [--install]` | чекпоинт с минимальным val loss вместо финального |

**Финальный адаптер почти никогда не лучший.** На датасете постов замеренная
кривая: val loss 2.137 → **1.212** (iter 50) → 1.753 → 1.473, при train loss,
падавшем с 2.053 до 0.431. Брать `adapters.safetensors` как есть — значит взять
переобученные веса.

## Проверки качества

Два независимых набора чистых функций, оба сравнивают ответ с эталоном:

- `style_checks.py` — стиль поста: эмодзи-заголовок, отсутствие AI-разметки,
  доля первого лица, длина, клише.
- `dictation_checks.py` — точность пост-процессора: похожесть на эталон,
  сохранность чисел и терминов латиницей, пунктуация, отсутствие преамбул.

**Калибровка обязательна.** `calibrate.py` и `dictation_calibrate.py` прогоняют
через проверки **эталонные тексты самого автора** и падают, если хоть одна не
проходит. Критерий, который валит эталон, штрафует модель за правильный ответ.
Обе первые редакции порогов калибровку не прошли и были исправлены — детали
в `criteria.md` соответствующего раздела.

`selftest.py` проверяет обратное: что проверки **ловят** дефект, а не всегда
возвращают «ок». Прогоняется без данных и моделей.

```bash
finetune/.venv/bin/python finetune/selftest.py
```

## Файлы

| Файл | Роль |
|---|---|
| `build_dataset.py` | vault → JSONL, `--map` печатает разметку абзацев |
| `corpus/posts.json` | 12 постов: пути в vault и синтезированные задания |
| `split.py` | group-split по исходному посту (защита от утечки) |
| `validate.py` | структура, роли, пустые поля, длины, дубли, утечка между сплитами |
| `providers.py` | протокол генерации → реестр → исполнитель (сейчас mlx) |
| `mlxenv.py` | поиск интерпретатора с mlx-lm |
| `_generate.py` | генерация внутри venv (импортирует `mlx_lm`) |
| `baseline.py` | прогон eval через модель, с адаптером и без |
| `train.py` | prepare / start / poll / status / logs / stop / best |
| `style_checks.py`, `dictation_checks.py` | чистые функции автопроверок |
| `calibrate.py`, `dictation_calibrate.py` | пороги vs эталоны автора |
| `selftest.py` | самотесты чистых функций |
| `evaluate.py` | таблица baseline против тюна |

`.venv/`, `adapters/`, `runs/`, `tuned/` — производные, не коммитятся.
`data/` и `baseline/` коммитятся: это зафиксированная точка отсчёта.

## Гиперпараметры

Дефолты подобраны под небольшой датасет на M2/16 ГБ: `--batch-size 1`,
`--num-layers 8`, `--max-seq-length 2048`, `--iters 300`, `--learning-rate 1e-5`,
чекпоинт каждые 50 итераций, val loss по всему eval. Замеренный пик памяти —
11.1 ГБ, скорость 11.4 с/итерация.

Для датасета диктовки (1516 обучающих примеров) поднимать `--iters` до 600–900.
При нехватке памяти — снизить `--num-layers` или перейти на
`mlx-community/Qwen2.5-3B-Instruct-4bit` через `--model`; датасет менять не надо.
