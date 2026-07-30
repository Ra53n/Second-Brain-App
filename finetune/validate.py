#!/usr/bin/env python3
"""Валидация JSONL-датасета. Любая ошибка → exit code 1.

    python3 validate.py data/train.jsonl data/valid.jsonl

Проверяет структуру каждой строки, единый system, длины, мусор разметки,
согласованность с sidecar-метаданными и отсутствие утечки постов между
train и valid.
"""

import argparse
import json
import os
import re
import sys
from typing import Dict, List, Optional, Set, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))

ROLES = ("system", "user", "assistant")
# Нижний порог ловит пустые и обрезанные примеры, а не короткие тексты как класс:
# открывающие строки анонса законно укладываются в ~130 символов.
MIN_ASSISTANT = 120
MAX_ASSISTANT = 6000
MIN_USER = 20
# Разметка, которой нет в живых постах автора: если просочилась — датасет учит
# модель писать как нейронка, ради чего всё и затевалось (см. criteria.md).
JUNK = [
    ("markdown-подзаголовок ###", re.compile(r"^\s*#{2,}\s", re.M)),
    ("галочка ✅", re.compile(r"✅")),
    ("незакрытый wikilink", re.compile(r"\[\[")),
    ("YAML-фронтматтер", re.compile(r"\A---\s*$", re.M)),
]


class Report:
    def __init__(self) -> None:
        self.errors: List[str] = []
        self.notes: List[str] = []

    def error(self, where: str, message: str) -> None:
        self.errors.append("%s: %s" % (where, message))

    def note(self, message: str) -> None:
        self.notes.append(message)


def read_jsonl(path: str, report: Report) -> List[Dict]:
    rows = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            if not line.strip():
                report.error("%s:%d" % (path, lineno), "пустая строка")
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                report.error("%s:%d" % (path, lineno), "невалидный JSON — %s" % exc)
    return rows


def check_file(path: str, system: str, report: Report, max_reuse: int) -> Tuple[List[Dict], List[Dict]]:
    rows = read_jsonl(path, report)
    meta_path = path.replace(".jsonl", ".meta.jsonl")
    meta = read_jsonl(meta_path, report) if os.path.exists(meta_path) else []
    if not meta:
        report.error(meta_path, "нет sidecar-метаданных")
    elif len(meta) != len(rows):
        report.error(path, "строк %d, а в метаданных %d" % (len(rows), len(meta)))

    seen_pairs: Set[Tuple[str, str]] = set()
    reuse: Dict[str, int] = {}

    for lineno, row in enumerate(rows, 1):
        where = "%s:%d" % (path, lineno)
        messages = row.get("messages")
        if not isinstance(messages, list):
            report.error(where, "нет списка messages")
            continue
        if len(messages) != 3:
            report.error(where, "ожидалось 3 сообщения, найдено %d" % len(messages))
            continue

        contents: List[str] = []
        for expected, message in zip(ROLES, messages):
            role = message.get("role")
            content = message.get("content")
            if role != expected:
                report.error(where, "роль %r вместо %r" % (role, expected))
            if not isinstance(content, str) or not content.strip():
                report.error(where, "пустой content у роли %r" % role)
                contents.append("")
                continue
            contents.append(content)

        if len(contents) != 3 or not all(contents):
            continue
        sys_text, user, assistant = contents

        if sys_text != system:
            report.error(where, "system отличается от system_prompt.txt")
        if len(user) < MIN_USER:
            report.error(where, "user короче %d символов (%d)" % (MIN_USER, len(user)))
        if not MIN_ASSISTANT <= len(assistant) <= MAX_ASSISTANT:
            report.error(
                where,
                "assistant %d символов, допустимо %d–%d" % (len(assistant), MIN_ASSISTANT, MAX_ASSISTANT),
            )
        for label, pattern in JUNK:
            if pattern.search(assistant):
                report.error(where, "в assistant запрещённая разметка: %s" % label)

        pair = (user.strip(), assistant.strip())
        if pair in seen_pairs:
            report.error(where, "полный дубль примера (совпали и user, и assistant)")
        seen_pairs.add(pair)
        key = assistant.strip()
        reuse[key] = reuse.get(key, 0) + 1

    over = [count for count in reuse.values() if count > max_reuse]
    if over:
        report.error(path, "%d текстов assistant повторяются чаще %d раз" % (len(over), max_reuse))
    if reuse:
        report.note(
            "%s: %d строк, уникальных текстов assistant %d" % (path, len(rows), len(reuse))
        )
    return rows, meta


def check_split(files: List[str], metas: Dict[str, List[Dict]], counts: Dict[str, int], report: Report,
                share_bounds: Tuple[float, float] = (0.70, 0.85)) -> None:
    posts: Dict[str, Set[str]] = {}
    for path in files:
        posts[path] = set(item.get("source_post", "") for item in metas.get(path, []))

    names = list(posts)
    for i, left in enumerate(names):
        for right in names[i + 1 :]:
            shared = posts[left] & posts[right]
            if shared:
                report.error(
                    "split",
                    "утечка: посты %s есть и в %s, и в %s"
                    % (", ".join(sorted(shared)), os.path.basename(left), os.path.basename(right)),
                )

    total = sum(counts.values())
    train = next((path for path in files if "train" in os.path.basename(path)), None)
    if train and total:
        share = counts[train] / total
        low, high = share_bounds
        if not low <= share <= high:
            report.error("split", "доля train %.0f%%, ожидалось %.0f–%.0f%%" % (share * 100, low * 100, high * 100))
        report.note("train %d (%.0f%%), остальное %d" % (counts[train], share * 100, total - counts[train]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", help="jsonl-файлы датасета")
    parser.add_argument("--max-reuse", type=int, default=3,
                        help="сколько раз один текст assistant может повторяться (по умолчанию 3)")
    parser.add_argument("--system", default=os.path.join(HERE, "system_prompt.txt"),
                        help="файл эталонного system-промпта")
    parser.add_argument("--train-share-min", type=float, default=0.70)
    parser.add_argument("--train-share-max", type=float, default=0.85)
    parser.add_argument("--min-assistant", type=int, default=None,
                        help="переопределить нижний порог длины assistant (символы)")
    args = parser.parse_args()

    global MIN_ASSISTANT
    if args.min_assistant is not None:
        MIN_ASSISTANT = args.min_assistant

    with open(args.system, encoding="utf-8") as fh:
        system = fh.read().strip()

    report = Report()
    metas: Dict[str, List[Dict]] = {}
    counts: Dict[str, int] = {}
    for path in args.files:
        if not os.path.exists(path):
            report.error(path, "файл не найден")
            continue
        rows, meta = check_file(path, system, report, args.max_reuse)
        metas[path] = meta
        counts[path] = len(rows)

    if len(args.files) > 1:
        check_split(args.files, metas, counts, report,
                    (args.train_share_min, args.train_share_max))

    for note in report.notes:
        print(note)
    if report.errors:
        print("\nОШИБКИ (%d):" % len(report.errors), file=sys.stderr)
        for error in report.errors:
            print("  " + error, file=sys.stderr)
        return 1
    print("OK — датасет валиден")
    return 0


if __name__ == "__main__":
    sys.exit(main())
