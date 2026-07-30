#!/usr/bin/env python3
"""Прогон примеров из eval через модель и фиксация ответов.

Без --adapter и без тюна это baseline — точка отсчёта. Тем же кодом снимаются
ответы после тюна, чтобы сравнение шло на одинаковых промптах и настройках.

    # baseline базовой модели на задаче «диктовка»
    python3 baseline.py --data dictation/data --out dictation/baseline

    # те же промпты, но с обученным LoRA-адаптером
    python3 baseline.py --data dictation/data --adapter dictation/adapters \\
        --out dictation/tuned

Провайдер выбирается флагом; список — `python3 providers.py`.
"""

import argparse
import json
import os
import sys
from typing import Dict, List

import providers

HERE = os.path.dirname(os.path.abspath(__file__))


def read_jsonl(path: str) -> List[Dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def resolve(path: str) -> str:
    return path if os.path.isabs(path) else os.path.join(HERE, path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--provider", default="mlx", choices=sorted(providers.REGISTRY))
    parser.add_argument("--model", default=None, help="по умолчанию — модель провайдера")
    parser.add_argument("--data", default="data", help="каталог с eval-выборкой")
    parser.add_argument("--eval-file", default="valid.jsonl")
    parser.add_argument("--adapter", default=None, help="LoRA-адаптер (только mlx)")
    parser.add_argument("--out", default=None, help="каталог результатов")
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--max-tokens", type=int, default=900)
    parser.add_argument("--temperature", type=float, default=0.7)
    args = parser.parse_args()

    provider = providers.get(args.provider)
    model = args.model or provider.default_model
    data_dir = resolve(args.data)
    out_dir = resolve(args.out or ("tuned" if args.adapter else "baseline"))

    eval_path = os.path.join(data_dir, args.eval_file)
    meta_path = eval_path.replace(".jsonl", ".meta.jsonl")
    for path in (eval_path, meta_path):
        if not os.path.exists(path):
            sys.exit("Нет %s — сначала собери датасет и сделай split" % path)

    rows = read_jsonl(eval_path)[: args.count]
    meta = read_jsonl(meta_path)[: args.count]
    if len(rows) < args.count:
        print("В eval только %d примеров, беру все" % len(rows), file=sys.stderr)

    if not provider.available():
        sys.exit("Провайдер не готов.\n    %s" % provider.describe())

    items = []
    for row, info in zip(rows, meta):
        items.append({
            "id": info["id"],
            # Эталон модели не показываем — она должна написать свой ответ.
            "messages": [m for m in row["messages"] if m["role"] != "assistant"],
        })

    print("Провайдер %s, модель %s%s, примеров %d"
          % (provider.name, model,
             ", адаптер %s" % args.adapter if args.adapter else " (без тюна)", len(items)))

    try:
        generated = provider.generate(
            items, model=model, max_tokens=args.max_tokens,
            temperature=args.temperature, adapter=args.adapter,
        )
    except providers.ProviderError as exc:
        sys.exit(str(exc))

    os.makedirs(out_dir, exist_ok=True)
    payload = [{"id": item["id"], "text": generated.get(item["id"], "")} for item in items]
    with open(os.path.join(out_dir, "outputs.json"), "w", encoding="utf-8") as fh:
        json.dump({"provider": provider.name, "model": model,
                   "adapter": args.adapter, "temperature": args.temperature,
                   "results": payload}, fh, ensure_ascii=False, indent=2)

    for index, (row, info) in enumerate(zip(rows, meta), 1):
        user = next(m["content"] for m in row["messages"] if m["role"] == "user")
        reference = next(m["content"] for m in row["messages"] if m["role"] == "assistant")
        text = generated.get(info["id"], "")
        path = os.path.join(out_dir, "%02d-%s.md" % (index, info["id"]))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("# %s\n\n" % info["id"])
            fh.write("- провайдер: `%s`, модель: `%s`\n" % (provider.name, model))
            fh.write("- тип задания: `%s`\n" % info.get("task_type", "?"))
            fh.write("- адаптер: %s\n\n" % (args.adapter or "нет (baseline)"))
            fh.write("## Вход\n\n%s\n\n" % user)
            fh.write("## Ответ модели\n\n%s\n\n" % text)
            fh.write("## Эталон (текст автора)\n\n%s\n" % reference)

    print("Записано %d файлов в %s" % (len(rows), out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
