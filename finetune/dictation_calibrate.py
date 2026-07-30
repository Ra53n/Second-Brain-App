#!/usr/bin/env python3
"""Калибровка автопроверок диктовки по эталонам автора.

Эталон, поданный сам себе на вход, обязан пройти все применимые проверки.
Критерий, который валит собственный текст автора, штрафовал бы модель за
правильный ответ. Запускать после любой правки dictation_checks.py.

    python3 dictation_calibrate.py            exit≠0, если эталоны не проходят
"""

import argparse
import collections
import json
import os
import sys
from typing import Dict, List

import dictation_checks as checks

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DATA = os.path.join(HERE, "dictation", "data")


def read_jsonl(path: str) -> List[Dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", default=DEFAULT_DATA)
    parser.add_argument("--files", nargs="*", default=["train.jsonl", "valid.jsonl"])
    args = parser.parse_args()

    failures: Dict[str, List[str]] = collections.defaultdict(list)
    passed = total = skipped = examples = 0

    for name in args.files:
        path = os.path.join(args.data, name)
        if not os.path.exists(path):
            sys.exit("Нет %s" % path)
        for row in read_jsonl(path):
            reference = row["messages"][2]["content"]
            result = checks.score(reference, reference)
            passed += result["passed"]
            total += result["total"]
            examples += 1
            for check_name, ok, detail in result["checks"]:
                if ok is None:
                    skipped += 1
                elif not ok:
                    failures[check_name].append(detail)

    print("Эталонов: %d" % examples)
    print("Применимых проверок пройдено: %d/%d" % (passed, total))
    print("Неприменимых пропущено: %d" % skipped)

    if failures:
        print("\nПОРОГИ НЕ КАЛИБРОВАНЫ — эталоны автора не проходят:", file=sys.stderr)
        for name, items in sorted(failures.items(), key=lambda kv: -len(kv[1])):
            print("  %s — %d: %s" % (name, len(items), "; ".join(items[:5])), file=sys.stderr)
        return 1

    print("OK — все применимые проверки проходят на эталонах")
    return 0


if __name__ == "__main__":
    sys.exit(main())
