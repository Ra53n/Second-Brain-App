#!/usr/bin/env python3
"""Сравнение автопроверок: baseline против тюна.

    # задача «диктовка»
    python3 evaluate.py --checks dictation --data dictation/data \\
        --baseline dictation/baseline --tuned dictation/tuned

    # задача «пост в стиле канала»
    python3 evaluate.py --checks style

    # задача «поручения из встречи»
    python3 evaluate.py --checks actionitem --data meetings/data \\
        --baseline meetings/baseline --tuned meetings/tuned

Набор проверок выбирается флагом: `style` меряет стиль поста, `dictation` —
точность пост-процессора относительно эталона, `actionitem` — строгость
структурированного ответа. Критерии и правило приёмки — в criteria.md
соответствующего раздела.
"""

import argparse
import json
import os
import sys
from typing import Dict, List, Optional

import actionitem_checks
import dictation_checks
import style_checks

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK_SETS = {"style": style_checks, "dictation": dictation_checks,
              "actionitem": actionitem_checks}


def resolve(path: str) -> str:
    return path if os.path.isabs(path) else os.path.join(HERE, path)


def read_jsonl(path: str) -> List[Dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def load_outputs(directory: str) -> Dict[str, str]:
    path = os.path.join(resolve(directory), "outputs.json")
    if not os.path.exists(path):
        sys.exit("Нет %s — сначала запусти baseline.py" % path)
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
    # Старый формат — плоский список; новый — объект с метаданными прогона.
    results = payload["results"] if isinstance(payload, dict) else payload
    return {item["id"]: item["text"] for item in results}


def references(data_dir: str, eval_file: str) -> Dict[str, str]:
    rows = read_jsonl(os.path.join(resolve(data_dir), eval_file))
    meta = read_jsonl(os.path.join(resolve(data_dir), eval_file.replace(".jsonl", ".meta.jsonl")))
    return {
        info["id"]: next(m["content"] for m in row["messages"] if m["role"] == "assistant")
        for row, info in zip(rows, meta)
    }


def mark(ok: Optional[bool]) -> str:
    if ok is None:
        return "н/п"
    return "OK " if ok else "нет"


def table(rows: List[List[str]], headers: List[str]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    out = ["  ".join(h.ljust(widths[i]) for i, h in enumerate(headers)),
           "  ".join("-" * w for w in widths)]
    for row in rows:
        out.append("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checks", default="style", choices=sorted(CHECK_SETS))
    parser.add_argument("--data", default="data")
    parser.add_argument("--eval-file", default="valid.jsonl")
    parser.add_argument("--baseline", default="baseline")
    parser.add_argument("--tuned", default=None)
    parser.add_argument("--verbose", action="store_true", help="показать каждую проверку")
    args = parser.parse_args()

    checks = CHECK_SETS[args.checks]
    refs = references(args.data, args.eval_file)
    base = load_outputs(args.baseline)
    tuned: Optional[Dict[str, str]] = load_outputs(args.tuned) if args.tuned else None

    headers = ["пример", "baseline"] + (["тюн"] if tuned else [])
    rows: List[List[str]] = []
    totals = {"baseline": 0, "tuned": 0, "max": 0}
    wins = {"baseline": 0, "tuned": 0, "ничья": 0}

    for example_id, reference in refs.items():
        if example_id not in base:
            continue
        base_score = checks.score(base[example_id], reference)
        totals["baseline"] += base_score["passed"]
        totals["max"] += base_score["total"]
        row = [example_id[:36], "%d/%d" % (base_score["passed"], base_score["total"])]

        if tuned is not None:
            tuned_score = checks.score(tuned.get(example_id, ""), reference)
            totals["tuned"] += tuned_score["passed"]
            row.append("%d/%d" % (tuned_score["passed"], tuned_score["total"]))
            if tuned_score["passed"] > base_score["passed"]:
                wins["tuned"] += 1
            elif tuned_score["passed"] < base_score["passed"]:
                wins["baseline"] += 1
            else:
                wins["ничья"] += 1
        rows.append(row)

        if args.verbose:
            print("\n=== %s" % example_id)
            for name, ok, detail in base_score["checks"]:
                print("  baseline %-30s %s  %s" % (name, mark(ok), detail))
            if tuned is not None:
                for name, ok, detail in tuned_score["checks"]:
                    print("  тюн      %-30s %s  %s" % (name, mark(ok), detail))

    if not rows:
        sys.exit("Нет пересечения между eval и результатами генерации")

    print(table(rows, headers))
    print()
    print("Итого baseline: %d/%d проверок пройдено" % (totals["baseline"], totals["max"]))
    if tuned is not None:
        print("Итого тюн:      %d/%d проверок пройдено" % (totals["tuned"], totals["max"]))
        print("Разница: %+d" % (totals["tuned"] - totals["baseline"]))
        print("По примерам: тюн лучше в %d, хуже в %d, поровну в %d"
              % (wins["tuned"], wins["baseline"], wins["ничья"]))
    print("\nАвтопроверки закрывают формальную часть. Итоговое решение — по criteria.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
