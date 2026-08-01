#!/usr/bin/env python3
"""Калибровка автопроверок извлечения поручений по эталонам датасета.

Эталон, поданный сам себе на вход, обязан пройти все применимые проверки.
У строгого выхода это не подбор порогов, как у постов и диктовки, а проверка
самих проверок: противоречие в контракте (взаимоисключающие условия, опечатка
в имени ключа, неверная применимость) валит эталон и видно сразу.

Дополнительно калибровка ловит битую разметку сборщика: эталон, не проходящий
собственную схему, означает ошибку в build_meetings_dataset.py, а не в модели.

    python3 actionitem_calibrate.py           exit≠0, если эталоны не проходят
"""

import argparse
import collections
import json
import os
import sys
from typing import Dict, List

import actionitem_checks as checks

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DATA = os.path.join(HERE, "meetings", "data")


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
    passed = total = skipped = examples = positives = 0

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
            if checks.parse(reference):
                positives += 1
            for check_name, ok, detail in result["checks"]:
                if ok is None:
                    skipped += 1
                elif not ok:
                    failures[check_name].append(detail)

    print("Эталонов: %d (с поручениями %d, пустых %d)"
          % (examples, positives, examples - positives))
    print("Применимых проверок пройдено: %d/%d" % (passed, total))
    print("Неприменимых пропущено: %d" % skipped)

    if failures:
        print("\nПРОВЕРКИ ПРОТИВОРЕЧИВЫ — эталоны не проходят:", file=sys.stderr)
        for name, items in sorted(failures.items(), key=lambda kv: -len(kv[1])):
            print("  %s — %d: %s" % (name, len(items), "; ".join(items[:5])), file=sys.stderr)
        return 1

    print("OK — все применимые проверки проходят на эталонах")
    return 0


if __name__ == "__main__":
    sys.exit(main())
