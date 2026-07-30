#!/usr/bin/env python3
"""Автоматические проверки формата и стиля. Чистые функции, без I/O.

Пороги откалиброваны так, чтобы эталонные тексты автора проходили их полностью:
критерий, который валит собственный текст автора, наказывал бы модель за
правильный ответ. Калибровка воспроизводится `python3 calibrate.py`.

Проверка возвращает (имя, ok, деталь), где ok=None — «неприменимо»: часть
проверок имеет смысл не для всех типов заданий (у среза из середины поста нет
заголовка с эмодзи). Неприменимые в знаменатель не идут.
"""

import re
from typing import Dict, List, Optional, Tuple

# ok=None означает «проверка неприменима к этому заданию».
Check = Tuple[str, Optional[bool], str]

EMOJI = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF⬀-⯿←-⇿⤀-⥿]"
)
SENTENCE = re.compile(r"[^.!?…]+[.!?…]*")
FIRST_PERSON = re.compile(
    r"\b(я|мне|меня|мной|мой|моя|моё|мои|моего|моей|моих|сам|у меня)\b", re.I
)
CLICHES = [
    "в современном мире",
    "важно отметить",
    "давайте разберёмся",
    "давайте разберемся",
    "в заключение",
    "не секрет, что",
    "стоит отметить",
    "в данной статье",
    "подводя итог",
    "итак, подведём итоги",
]

# База по жирному: в живых постах его нет вовсе, два вхождения — одна выделенная
# мысль. Для статей порог поднимается от эталона (см. check_bold) — там жирный
# законная часть жанра.
MAX_BOLD = 2
BOLD_HEADROOM = 2
LENGTH_TOLERANCE = (0.5, 2.0)
# Нижняя граница 5.0 — короткие хуки автора идут по 5.6–7.8 слов на предложение.
SENTENCE_WORDS = (5.0, 22.0)
# Допуск по «личности» текста относительно эталона: абсолютного порога тут быть
# не может — отдельный фрагмент поста (объяснение, аналогия, список сервисов)
# законно бывает полностью безличным, и у автора таких хватает.
FIRST_PERSON_MARGIN = 0.15


def words(text: str) -> int:
    return len(re.findall(r"\S+", text))


def sentences(text: str) -> List[str]:
    return [s.strip() for s in SENTENCE.findall(text) if s.strip()]


def check_length(text: str, reference: str) -> Check:
    """Длина сверяется с эталоном, а не с фиксированным диапазоном: хук законно
    короче поста, и общий порог наказывал бы правильный ответ."""
    got, want = words(text), words(reference)
    if not want:
        return ("длина", False, "нет эталона")
    ratio = got / want
    low, high = LENGTH_TOLERANCE
    return ("длина", low <= ratio <= high, "%d слов при эталоне %d (×%.2f)" % (got, want, ratio))


def check_no_headings(text: str) -> Check:
    hits = len(re.findall(r"^\s*#{2,}\s", text, re.M))
    return ("без ##-подзаголовков", hits == 0, "найдено %d" % hits)


def check_no_checkmarks(text: str) -> Check:
    hits = text.count("✅")
    return ("без ✅-списков", hits == 0, "найдено %d" % hits)


def bold_count(text: str) -> int:
    return len(re.findall(r"\*\*[^*]+\*\*", text))


def check_bold(text: str, reference: str) -> Check:
    """Порог зависит от жанра эталона: пост — почти без жирного, раздел статьи
    размечает термины жирным законно. Требуем «не жирнее эталона с запасом»."""
    limit = max(MAX_BOLD, bold_count(reference) + BOLD_HEADROOM)
    hits = bold_count(text)
    return ("жирного ≤ %d" % limit, hits <= limit, "найдено %d при эталонных %d" % (hits, bold_count(reference)))


def first_line(text: str) -> str:
    return next((line for line in text.splitlines() if line.strip()), "")


def check_emoji_opening(text: str, reference: str) -> Check:
    """Применимо только там, где эталон сам открывается эмодзи: у среза из
    середины поста и у постов без эмодзи-заголовка требовать его нельзя."""
    if not EMOJI.search(first_line(reference)):
        return ("эмодзи в первой строке", None, "эталон без эмодзи — не проверяем")
    got = first_line(text)
    return ("эмодзи в первой строке", bool(EMOJI.search(got)), got[:60])


def check_sentence_length(text: str) -> Check:
    parts = sentences(text)
    if not parts:
        return ("средняя длина предложения", False, "нет предложений")
    avg = sum(words(s) for s in parts) / len(parts)
    low, high = SENTENCE_WORDS
    return ("средняя длина предложения", low <= avg <= high, "%.1f слов" % avg)


def first_person_share(text: str) -> Optional[float]:
    parts = sentences(text)
    if not parts:
        return None
    return sum(1 for s in parts if FIRST_PERSON.search(s)) / len(parts)


def check_first_person(text: str, reference: str) -> Check:
    """Сравнение с эталоном, а не с фиксированным порогом: требуем лишь, чтобы
    модель не оказалась заметно безличнее автора на том же задании."""
    got = first_person_share(text)
    want = first_person_share(reference)
    if got is None or want is None:
        return ("первое лицо не ниже эталона", False, "нет предложений")
    floor = max(0.0, want - FIRST_PERSON_MARGIN)
    return (
        "первое лицо не ниже эталона",
        got >= floor,
        "%.0f%% при эталонных %.0f%%" % (got * 100, want * 100),
    )


def check_cliches(text: str) -> Check:
    lowered = text.lower()
    found = [phrase for phrase in CLICHES if phrase in lowered]
    return ("без AI-клише", not found, ", ".join(found) if found else "нет")


def run_checks(text: str, reference: str) -> List[Check]:
    return [
        check_length(text, reference),
        check_no_headings(text),
        check_no_checkmarks(text),
        check_bold(text, reference),
        check_emoji_opening(text, reference),
        check_sentence_length(text),
        check_first_person(text, reference),
        check_cliches(text),
    ]


def score(text: str, reference: str) -> Dict:
    checks = run_checks(text, reference)
    applicable = [ok for _, ok, _ in checks if ok is not None]
    return {
        "passed": sum(1 for ok in applicable if ok),
        "total": len(applicable),
        "checks": checks,
    }
