#!/usr/bin/env python3
"""Автопроверки для задачи «сырая диктовка → готовый текст». Чистые функции.

Здесь другой предмет измерения, чем в style_checks.py: у поста нет единственно
верного ответа, а у пост-процессора диктовки есть — эталон, который автор
реально отправил. Поэтому главная ось не стиль, а точность относительно эталона.

Проверка возвращает (имя, ok, деталь); ok=None — «неприменимо».
Пороги калибруются `dictation_calibrate.py`: эталон, поданный сам себе на вход,
обязан проходить все применимые проверки.
"""

import difflib
import re
from typing import Dict, List, Optional, Tuple

Check = Tuple[str, Optional[bool], str]

WORD = re.compile(r"\w+", re.UNICODE)
NUMBER = re.compile(r"\d+(?:[.,]\d+)?")
LATIN = re.compile(r"\b[A-Za-z][A-Za-z0-9._/-]{1,}\b")
PUNCT = re.compile(r"[.,!?;:—–-]")
SENTENCE_START = re.compile(r"(?:^|[.!?…]\s+)([А-Яа-яA-Za-z])")

# Модель обязана вернуть только текст. Всё это — признаки, что она заговорила
# с пользователем вместо работы. Слова общей вежливости («конечно», «разумеется»)
# сюда не берём: в речи автора это обычные вводные, и проверка ловила бы эталон.
PREAMBLES = [
    "вот исправленный", "вот отредактированный", "вот готовый", "вот итоговый",
    "исправленный текст", "отредактированный текст", "итоговый текст:",
    "надеюсь, это помогло", "готово:", "результат:", "ответ:",
    "here is", "here's the", "sure,", "certainly,",
]
PREAMBLE_WINDOW = 60

MIN_SIMILARITY = 0.55
LENGTH_TOLERANCE = (0.6, 1.6)
# Автор диктует продолжениями фраз, и эталон законно начинается со строчной.
# Поэтому доля заглавных сверяется с эталоном, а не с абсолютным порогом.
CAPITALIZATION_MARGIN = 0.2
# Плотность знаков препинания в сыром ASR близка к нулю; требуем не сильно ниже
# эталонной, иначе модель просто перепечатала вход.
PUNCT_RATIO_MARGIN = 0.4


def words(text: str) -> List[str]:
    return WORD.findall(text.lower())


def similarity(text: str, reference: str) -> float:
    """Доля совпадения по словам, 0..1 — основная метрика точности."""
    return difflib.SequenceMatcher(None, words(text), words(reference)).ratio()


def check_similarity(text: str, reference: str) -> Check:
    value = similarity(text, reference)
    return ("похожесть на эталон", value >= MIN_SIMILARITY, "%.2f" % value)


def check_length(text: str, reference: str) -> Check:
    got, want = len(words(text)), len(words(reference))
    if not want:
        return ("длина", None, "нет эталона")
    ratio = got / want
    low, high = LENGTH_TOLERANCE
    return ("длина", low <= ratio <= high, "%d слов при эталоне %d (×%.2f)" % (got, want, ratio))


def check_no_preamble(text: str) -> Check:
    head = text.strip().lower()[:PREAMBLE_WINDOW]
    found = [p for p in PREAMBLES if p in head]
    return ("без преамбулы", not found, found[0] if found else "нет")


def check_no_wrapper(text: str) -> Check:
    """Ответ не должен быть обёрнут в кавычки или блок кода."""
    stripped = text.strip()
    problems = []
    if stripped.startswith("```") or stripped.endswith("```"):
        problems.append("блок кода")
    if len(stripped) > 2 and stripped[0] in "\"«'" and stripped[-1] in "\"»'":
        problems.append("кавычки вокруг всего текста")
    return ("без обёртки", not problems, ", ".join(problems) or "нет")


def check_no_markdown(text: str, reference: str) -> Check:
    """Разметку добавлять нельзя — если её нет в эталоне."""
    pattern = re.compile(r"^\s*(#{1,6}\s|[-*+]\s|\d+\.\s)", re.M)
    if pattern.search(reference):
        return ("не добавляет разметку", None, "эталон сам размечен")
    hits = len(pattern.findall(text))
    return ("не добавляет разметку", hits == 0, "найдено %d" % hits)


def _kept(source: str, text: str, pattern: re.Pattern) -> Tuple[int, int]:
    wanted = set(pattern.findall(source))
    if not wanted:
        return 0, 0
    present = set(pattern.findall(text))
    return len(wanted & present), len(wanted)


def check_numbers(text: str, reference: str) -> Check:
    kept, total = _kept(reference, text, NUMBER)
    if not total:
        return ("числа сохранены", None, "в эталоне чисел нет")
    return ("числа сохранены", kept == total, "%d из %d" % (kept, total))


def check_latin_terms(text: str, reference: str) -> Check:
    """Термины и названия латиницей — то, что модель чаще всего перевирает."""
    kept, total = _kept(reference, text, LATIN)
    if not total:
        return ("термины латиницей сохранены", None, "в эталоне их нет")
    return ("термины латиницей сохранены", kept == total, "%d из %d" % (kept, total))


def punct_ratio(text: str) -> float:
    total = len(words(text))
    return len(PUNCT.findall(text)) / total if total else 0.0


def check_punctuation(text: str, reference: str) -> Check:
    """Главная работа пост-процессора: расставить знаки, которых нет в ASR."""
    got, want = punct_ratio(text), punct_ratio(reference)
    if want == 0:
        return ("пунктуация проставлена", None, "в эталоне знаков нет")
    floor = want * (1 - PUNCT_RATIO_MARGIN)
    return ("пунктуация проставлена", got >= floor,
            "%.2f знака/слово при эталонных %.2f" % (got, want))


def capitalization_share(text: str) -> Optional[float]:
    starts = SENTENCE_START.findall(text)
    if not starts:
        return None
    return sum(1 for ch in starts if ch.isupper()) / len(starts)


def check_capitalization(text: str, reference: str) -> Check:
    got, want = capitalization_share(text), capitalization_share(reference)
    if got is None or want is None:
        return ("заглавные не ниже эталона", None, "нет предложений")
    floor = max(0.0, want - CAPITALIZATION_MARGIN)
    return ("заглавные не ниже эталона", got >= floor,
            "%.0f%% при эталонных %.0f%%" % (got * 100, want * 100))


def run_checks(text: str, reference: str) -> List[Check]:
    return [
        check_similarity(text, reference),
        check_length(text, reference),
        check_punctuation(text, reference),
        check_capitalization(text, reference),
        check_numbers(text, reference),
        check_latin_terms(text, reference),
        check_no_preamble(text),
        check_no_wrapper(text),
        check_no_markdown(text, reference),
    ]


def score(text: str, reference: str) -> Dict:
    checks = run_checks(text, reference)
    applicable = [ok for _, ok, _ in checks if ok is not None]
    return {
        "passed": sum(1 for ok in applicable if ok),
        "total": len(applicable),
        "checks": checks,
    }
