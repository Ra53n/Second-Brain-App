#!/usr/bin/env python3
"""Перевод датасета встреч на русский: корпус английский, встречи автора русские.

Роли говорящих и поле assignee переводятся таблицей, а не моделью: имя роли
в реплике и в эталоне обязано совпадать до символа, иначе проверка
«ответственные совпадают» ловила бы не ошибку модели, а разнобой перевода.
Модели достаётся только живой текст — реплики и формулировки задач.

Ключ берётся по правилам проекта: env SECONDBRAIN_<ID>_KEY, иначе Keychain
(service = com.local.second-brain.apikeys, account = <id>). В файлы не пишется.

    python3 translate_ru.py --data meetings/data          перевод + кеш
    python3 translate_ru.py --data meetings/data --share 0.85
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
import zlib
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
KEYCHAIN_SERVICE = "com.local.second-brain.apikeys"

PROVIDERS = {
    "deepseek": ("https://api.deepseek.com/v1/chat/completions", "deepseek-chat"),
    "openai": ("https://api.openai.com/v1/chat/completions", "gpt-4.1-mini"),
    "openrouter": ("https://openrouter.ai/api/v1/chat/completions", "deepseek/deepseek-chat"),
}

ROLES_RU = {
    "Project Manager": "Руководитель проекта",
    "Industrial Designer": "Промышленный дизайнер",
    "User Interface Designer": "Дизайнер интерфейса",
    "Marketing Expert": "Маркетолог",
}

SYSTEM = (
    "Ты переводишь расшифровку рабочей встречи с английского на русский. "
    "Это живая устная речь: сохраняй разговорность, оговорки, обрывы фраз и "
    "слова-паразиты — не превращай её в гладкий письменный текст. "
    "Переводи только текст реплик, строки и их порядок не меняй, имена ролей "
    "перед двоеточием оставляй ровно как есть. В ответе — только перевод."
)
TASKS_SYSTEM = (
    "Ты переводишь с английского на русский короткие формулировки рабочих "
    "поручений. Отвечай JSON-массивом строк той же длины, что и на входе, "
    "в том же порядке. Без пояснений."
)


def cache_key(record: Dict) -> str:
    """Ключ кеша — отпечаток исходной пары «фрагмент + эталон», не id примера.

    Пересборка датасета сохраняет id (`<встреча>_<номер окна>`), но меняет
    содержимое окна. По id кеш подставил бы перевод ЧУЖОГО текста — молча и
    без единой ошибки в логах.
    """
    source = record["messages"][1]["content"] + "\x00" + record["messages"][2]["content"]
    return hashlib.sha1(source.encode("utf-8")).hexdigest()


def read_key(provider: str) -> str:
    env = "SECONDBRAIN_%s_KEY" % provider.upper()
    value = os.environ.get(env, "").strip()
    if value:
        return value
    try:
        found = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
             "-a", provider, "-w"],
            capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, OSError):
        sys.exit("Нет ключа %s: ни в %s, ни в Keychain." % (provider, env))
    # Пустая запись в Keychain иначе обернулась бы 401 на каждой строке датасета.
    key = found.stdout.strip()
    if not key:
        sys.exit("Ключ %s в Keychain пуст." % provider)
    return key


def complete(url: str, model: str, key: str, system: str, user: str) -> str:
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "temperature": 0.2,
    }).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer %s" % key,
    })
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.load(response)
    return payload["choices"][0]["message"]["content"].strip()


def translate_record(url: str, model: str, key: str, record: Dict) -> Optional[Dict]:
    """Одна запись датасета целиком. None — перевод не сошёлся по структуре."""
    user = record["messages"][1]["content"]
    lines = user.split("\n")
    localized = []
    for line in lines:
        role, _, text = line.partition(": ")
        localized.append("%s: %s" % (ROLES_RU.get(role, role), text))
    translated = complete(url, model, key, SYSTEM, "\n".join(localized))
    translated_lines = translated.split("\n")
    # Модель обязана сохранить построчную структуру: если она склеила или
    # разбила реплики, привязка поручения к говорящему поедет. Такой ответ не берём.
    if len(translated_lines) != len(lines):
        return None

    answer = json.loads(record["messages"][2]["content"])
    items = answer["action_items"]
    if items:
        source = [item["task"] for item in items] + \
                 [item["due"] for item in items if item["due"]]
        raw = complete(url, model, key, TASKS_SYSTEM,
                       json.dumps(source, ensure_ascii=False))
        raw = raw.strip().strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:].strip()
        try:
            parts = json.loads(raw)
        except ValueError:
            return None
        if not isinstance(parts, list) or len(parts) != len(source):
            return None
        # Модель иногда возвращает null или объект вместо строки: такой «перевод»
        # уехал бы прямо в эталон и сломал бы схему элемента.
        if any(not isinstance(part, str) or not part.strip() for part in parts):
            return None
        tasks = parts[:len(items)]
        dues = iter(parts[len(items):])
        for item, task in zip(items, tasks):
            item["task"] = task
            if item["due"]:
                item["due"] = next(dues)
            if item["assignee"]:
                item["assignee"] = ROLES_RU.get(item["assignee"], item["assignee"])

    return {
        "user": "\n".join(translated_lines),
        "assistant": json.dumps({"action_items": items}, ensure_ascii=False),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", default=os.path.join(HERE, "meetings", "data"))
    parser.add_argument("--provider", default="deepseek", choices=sorted(PROVIDERS))
    parser.add_argument("--model", default=None)
    parser.add_argument("--share", type=float, default=0.85,
                        help="доля примеров на перевод; остальные остаются английскими")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--limit", type=int, default=0, help="перевести не больше N (проба)")
    args = parser.parse_args()

    data = args.data if os.path.isabs(args.data) else os.path.join(HERE, args.data)
    url, default_model = PROVIDERS[args.provider]
    model = args.model or default_model
    key = read_key(args.provider)

    raw_path = os.path.join(data, "raw.jsonl")
    meta_path = os.path.join(data, "raw.meta.jsonl")
    cache_path = os.path.join(data, "translations.json")
    with open(raw_path, encoding="utf-8") as fh:
        rows = [json.loads(line) for line in fh if line.strip()]
    with open(meta_path, encoding="utf-8") as fh:
        meta = [json.loads(line) for line in fh if line.strip()]

    cache: Dict[str, Dict] = {}
    if os.path.exists(cache_path):
        with open(cache_path, encoding="utf-8") as fh:
            cache = json.load(fh)

    # Английским остаётся каждый k-й пример по устойчивому хэшу содержимого, а не по
    # позиции в файле: пересборка датасета меняет порядок строк, и от позиции срез
    # поехал бы. Хвост списка брать тоже нельзя — сплит группирует по встречам,
    # и целые встречи оказались бы одноязычными.
    step = max(2, int(round(1 / max(1 - args.share, 1e-6)))) if args.share < 1 else 0
    # Уже переведённое не трогаем: скрипт переписывает raw.jsonl на месте, и без
    # этого guard'а второй запуск оплатил бы перевод русского текста заново.
    targets = [(row, item) for row, item in zip(rows, meta)
               if item.get("lang") != "ru"
               and (not step or zlib.crc32(cache_key(row).encode("ascii")) % step)]
    keep_ru = {cache_key(row) for row, _ in targets}
    pending = [(row, item) for row, item in targets if cache_key(row) not in cache]
    if args.limit:
        pending = pending[:args.limit]

    failures: List[str] = []
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(translate_record, url, model, key, row): (cache_key(row), item["id"])
                   for row, item in pending}
        for future in concurrent.futures.as_completed(futures):
            fingerprint, example_id = futures[future]
            try:
                result = future.result()
            # Ловим широко намеренно: сеть роняет чем угодно (IncompleteRead,
            # RemoteDisconnected, таймаут), а уронить весь прогон перед записью
            # кеша — потерять оплаченную работу. Неудачи видны в отчёте ниже.
            except Exception as error:  # noqa: BLE001
                failures.append("%s: %s: %s" % (example_id, type(error).__name__, error))
                continue
            if result is None:
                failures.append("%s: структура перевода не совпала" % example_id)
                continue
            cache[fingerprint] = result
            done += 1
            if done % 25 == 0:
                with open(cache_path, "w", encoding="utf-8") as fh:
                    json.dump(cache, fh, ensure_ascii=False)
                sys.stderr.write("переведено %d/%d\n" % (done, len(pending)))

    with open(cache_path, "w", encoding="utf-8") as fh:
        json.dump(cache, fh, ensure_ascii=False)

    translated = 0
    with open(raw_path, "w", encoding="utf-8") as data_fh, \
            open(meta_path, "w", encoding="utf-8") as meta_fh:
        for row, item in zip(rows, meta):
            fingerprint = cache_key(row)
            found = cache.get(fingerprint) if fingerprint in keep_ru else None
            if item.get("lang") == "ru":
                translated += 1  # уже по-русски с прошлого запуска, кеш не нужен
            if found:
                row["messages"][1]["content"] = found["user"]
                row["messages"][2]["content"] = found["assistant"]
                item["lang"] = "ru"
                translated += 1
            data_fh.write(json.dumps(row, ensure_ascii=False) + "\n")
            meta_fh.write(json.dumps(item, ensure_ascii=False) + "\n")

    print("примеров: %d, по-русски: %d, по-английски: %d"
          % (len(rows), translated, len(rows) - translated))
    for line in failures[:10]:
        sys.stderr.write(line + "\n")
    if len(failures) > 10:
        sys.stderr.write("...ещё %d неудач\n" % (len(failures) - 10))
    # Прогон, где не удалась ни одна запись, успешным считаться не может (P6).
    return 1 if pending and not done else 0


if __name__ == "__main__":
    sys.exit(main())
