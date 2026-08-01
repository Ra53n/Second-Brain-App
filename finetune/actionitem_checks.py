#!/usr/bin/env python3
"""Автопроверки для задачи «фрагмент встречи → поручения». Чистые функции.

Предмет измерения третий по счёту и самый жёсткий. У поста нет единственно
верного ответа, у пост-процессора диктовки он есть, но меряется похожестью.
Здесь ответ либо точен, либо неверен: выдуманное поручение или подставленный
срок — не «чуть хуже», а ошибка, ради отлова которой датасет и заводился.

Проверка возвращает (имя, ok, деталь); ok=None — «неприменимо».
Пороги калибруются `actionitem_calibrate.py`. Калибровка здесь слабее, чем у
двух других наборов: у строгого выхода эталон проходит проверки по построению,
и её задача — поймать не порог, а противоречие в самих проверках.
"""

import difflib
import json
import re
from collections import Counter
from typing import Dict, List, Optional, Tuple

Check = Tuple[str, Optional[bool], str]

KEY = "action_items"
ITEM_KEYS = {"assignee", "task", "due"}
FENCE = re.compile(r"```")
MIN_TASK_SIMILARITY = 0.5


def parse(raw: str) -> Optional[List[Dict]]:
    """Строгий разбор ответа модели. None — контракт нарушен."""
    try:
        value = json.loads(raw.strip())
    except (ValueError, AttributeError):
        return None
    if not isinstance(value, dict) or set(value) != {KEY}:
        return None
    items = value[KEY]
    return items if isinstance(items, list) else None


def normalize(text: Optional[str]) -> str:
    return " ".join((text or "").lower().split())


def run_checks(text: str, reference: str) -> List[Check]:
    checks: List[Check] = []
    model = parse(text)
    expected = parse(reference) or []

    ok = model is not None
    checks.append(("валидный JSON", ok,
                   "объект с единственным ключом %s" % KEY if ok
                   else "ответ не разобран как объект {%s: [...]}" % KEY))

    # Проверка поверхностная и от разбора не зависит: заговорившая модель роняет
    # обе проверки сразу, и это верно — такой ответ и нечитаем, и болтлив.
    stripped = (text or "").strip()
    clean = stripped.startswith("{") and stripped.endswith("}") and not FENCE.search(stripped)
    checks.append(("без прозы", clean,
                   "только JSON" if clean else "вокруг JSON есть текст или ```-обёртка"))

    if model is None:
        for name in ("схема элементов", "число поручений",
                     "ничего не выдумано", "ничего не упущено",
                     "ответственные совпадают", "срок не выдуман",
                     "формулировка задачи"):
            checks.append((name, None, "неприменимо: JSON не разобран"))
        return checks

    bad = [item for item in model
           if not isinstance(item, dict) or set(item) != ITEM_KEYS
           or not isinstance(item.get("task"), str) or not item["task"].strip()
           or not isinstance(item.get("assignee"), (str, type(None)))
           or not isinstance(item.get("due"), (str, type(None)))]
    checks.append(("схема элементов", not bad,
                   "все элементы по схеме" if not bad
                   else "элементов с нарушенной схемой: %d" % len(bad)))

    same = len(model) == len(expected)
    checks.append(("число поручений", same,
                   "%d = %d" % (len(model), len(expected)) if same
                   else "%d вместо %d" % (len(model), len(expected))))

    if expected:
        checks.append(("ничего не выдумано", None, "неприменимо: во фрагменте есть поручения"))
        found = len(model) > 0
        checks.append(("ничего не упущено", found,
                       "поручения найдены" if found else "модель вернула пустой список"))
    else:
        empty = len(model) == 0
        checks.append(("ничего не выдумано", empty,
                       "пустой список" if empty
                       else "выдумано поручений: %d" % len(model)))
        checks.append(("ничего не упущено", None, "неприменимо: во фрагменте нет поручений"))

    if not expected:
        for name in ("ответственные совпадают", "срок не выдуман", "формулировка задачи"):
            checks.append((name, None, "неприменимо: во фрагменте нет поручений"))
        return checks

    if bad:
        for name in ("ответственные совпадают", "срок не выдуман", "формулировка задачи"):
            checks.append((name, None, "неприменимо: схема элементов нарушена"))
        return checks

    model_names = Counter(normalize(item["assignee"]) for item in model)
    expected_names = Counter(normalize(item["assignee"]) for item in expected)
    match = model_names == expected_names
    checks.append(("ответственные совпадают", match,
                   "совпали" if match
                   else "%s вместо %s" % (sorted(model_names), sorted(expected_names))))

    # Срок сверяется односторонне: пропустить прозвучавший дедлайн — потеря,
    # но подставить несуществующий хуже, потому что выглядит как факт встречи.
    invented = sum(1 for item in model if item["due"]) - sum(1 for item in expected if item["due"])
    ok = invented <= 0
    checks.append(("срок не выдуман", ok,
                   "лишних сроков нет" if ok else "сроков больше эталона на %d" % invented))

    ratio = difflib.SequenceMatcher(
        None,
        " ".join(sorted(normalize(item["task"]) for item in model)),
        " ".join(sorted(normalize(item["task"]) for item in expected)),
    ).ratio()
    ok = ratio >= MIN_TASK_SIMILARITY
    checks.append(("формулировка задачи", ok, "похожесть %.2f (порог %.2f)"
                   % (ratio, MIN_TASK_SIMILARITY)))
    return checks


def score(text: str, reference: str) -> Dict:
    checks = run_checks(text, reference)
    applicable = [ok for _, ok, _ in checks if ok is not None]
    return {
        "passed": sum(1 for ok in applicable if ok),
        "total": len(applicable),
        "checks": checks,
    }
