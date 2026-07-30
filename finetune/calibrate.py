#!/usr/bin/env python3
"""Калибровка автопроверок по эталонам автора.

Прогоняет тексты `assistant` из датасета через style_checks и требует, чтобы
они прошли все применимые проверки. Смысл простой: критерий, который валит
собственный текст автора, штрафовал бы модель за правильный ответ.

    python3 calibrate.py            exit≠0, если эталоны не проходят

Запускать после любой правки порогов в style_checks.py.
"""

import argparse
import json
import os
import sys
from typing import Dict, List

import style_checks

HERE = os.path.dirname(os.path.abspath(__file__))


def read_jsonl(path: str) -> List[Dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", default=os.path.join(HERE, "data"))
    args = parser.parse_args()

    rows = read_jsonl(os.path.join(args.data, "raw.jsonl"))
    meta = read_jsonl(os.path.join(args.data, "raw.meta.jsonl"))

    failures: Dict[str, List[str]] = {}
    passed = total = skipped = 0

    for row, info in zip(rows, meta):
        reference = next(m["content"] for m in row["messages"] if m["role"] == "assistant")
        result = style_checks.score(reference, reference)
        passed += result["passed"]
        total += result["total"]
        for name, ok, detail in result["checks"]:
            if ok is None:
                skipped += 1
            elif not ok:
                failures.setdefault(name, []).append("%s (%s)" % (info["id"], detail))

    print("Эталоны автора: %d/%d применимых проверок пройдено" % (passed, total))
    print("Неприменимых пропущено: %d" % skipped)

    if failures:
        print("\nПОРОГИ НЕ КАЛИБРОВАНЫ — эталоны автора не проходят:", file=sys.stderr)
        for name, items in sorted(failures.items(), key=lambda kv: -len(kv[1])):
            print("  %s — %d примеров:" % (name, len(items)), file=sys.stderr)
            for item in items[:5]:
                print("      " + item, file=sys.stderr)
        return 1

    print("OK — все применимые проверки проходят на эталонах")
    return 0


if __name__ == "__main__":
    sys.exit(main())
