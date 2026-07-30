#!/usr/bin/env python3
"""Разделение датасета на train/valid.

Сплит идёт по ИСХОДНОМУ ПОСТУ, а не по примеру: один пост даёт до 4 примеров
разных типов, и если часть уедет в train, а часть в valid, eval начнёт мерить
запоминание вместо обобщения.

    python3 split.py                     детерминированно, seed из --seed
    python3 split.py --eval-posts a,b,c  явный список постов в valid
"""

import argparse
import json
import os
import random
import sys
from typing import Dict, List, Set

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SEED = 20260729


def read_jsonl(path: str) -> List[Dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def write_jsonl(path: str, rows: List[Dict]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def pick_eval_posts(meta: List[Dict], target: float, seed: int) -> Set[str]:
    """Набирает целые посты в valid, пока не наберётся нужная доля примеров."""
    per_post: Dict[str, int] = {}
    order: List[str] = []
    for item in meta:
        post = item["source_post"]
        if post not in per_post:
            per_post[post] = 0
            order.append(post)
        per_post[post] += 1

    need = round(len(meta) * target)
    shuffled = list(order)
    random.Random(seed).shuffle(shuffled)

    chosen: Set[str] = set()
    taken = 0
    for post in shuffled:
        if taken >= need:
            break
        chosen.add(post)
        taken += per_post[post]
    return chosen


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", default=os.path.join(HERE, "data"))
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--eval-fraction", type=float, default=0.2)
    parser.add_argument("--eval-posts", default="", help="id постов через запятую")
    args = parser.parse_args()

    raw = os.path.join(args.data, "raw.jsonl")
    raw_meta = os.path.join(args.data, "raw.meta.jsonl")
    for path in (raw, raw_meta):
        if not os.path.exists(path):
            sys.exit("Нет %s — сначала запусти build_dataset.py" % path)

    rows = read_jsonl(raw)
    meta = read_jsonl(raw_meta)
    if len(rows) != len(meta):
        sys.exit("raw.jsonl (%d) и raw.meta.jsonl (%d) разошлись" % (len(rows), len(meta)))

    if args.eval_posts:
        eval_posts = set(part.strip() for part in args.eval_posts.split(",") if part.strip())
        known = set(item["source_post"] for item in meta)
        unknown = eval_posts - known
        if unknown:
            sys.exit("Неизвестные посты: %s" % ", ".join(sorted(unknown)))
    else:
        eval_posts = pick_eval_posts(meta, args.eval_fraction, args.seed)

    buckets: Dict[str, List[int]] = {"train": [], "valid": []}
    for index, item in enumerate(meta):
        buckets["valid" if item["source_post"] in eval_posts else "train"].append(index)

    for name, indexes in buckets.items():
        write_jsonl(os.path.join(args.data, "%s.jsonl" % name), [rows[i] for i in indexes])
        write_jsonl(os.path.join(args.data, "%s.meta.jsonl" % name), [meta[i] for i in indexes])

    summary = {
        "seed": args.seed if not args.eval_posts else None,
        "eval_fraction_target": args.eval_fraction,
        "eval_posts": sorted(eval_posts),
        "counts": {name: len(indexes) for name, indexes in buckets.items()},
    }
    with open(os.path.join(args.data, "split.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    total = len(rows)
    print("train %d (%.0f%%), valid %d (%.0f%%)" % (
        len(buckets["train"]), 100 * len(buckets["train"]) / total,
        len(buckets["valid"]), 100 * len(buckets["valid"]) / total,
    ))
    print("посты в valid: %s" % ", ".join(sorted(eval_posts)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
