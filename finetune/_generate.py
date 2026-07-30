#!/usr/bin/env python3
"""Генерация ответов через mlx-lm. Запускается интерпретатором из venv.

    <venv>/bin/python _generate.py job.json out.json

job.json: {"model": ..., "adapter": путь или null, "max_tokens": N,
           "temperature": T, "items": [{"id": ..., "messages": [...]}]}

Вынесен отдельным файлом, потому что импортировать mlx_lm можно только из
окружения с ним; управляющие скрипты живут на системном Python.
"""

import json
import sys

from mlx_lm import generate, load


def build_prompt(tokenizer, messages):
    """Разные версии mlx-lm возвращают из шаблона то строку, то токены."""
    try:
        prompt = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
    except TypeError:
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    if not isinstance(prompt, str):
        prompt = tokenizer.decode(prompt)
    return prompt


def make_generate_kwargs(temperature):
    """В свежих версиях сэмплер отдельный объект, в старых — аргумент temp."""
    try:
        from mlx_lm.sample_utils import make_sampler

        return {"sampler": make_sampler(temp=temperature)}
    except ImportError:
        return {"temp": temperature}


def main() -> int:
    with open(sys.argv[1], encoding="utf-8") as fh:
        job = json.load(fh)

    model, tokenizer = load(job["model"], adapter_path=job.get("adapter"))
    extra = make_generate_kwargs(job.get("temperature", 0.7))

    results = []
    for index, item in enumerate(job["items"], 1):
        prompt = build_prompt(tokenizer, item["messages"])
        print("[%d/%d] %s" % (index, len(job["items"]), item["id"]), file=sys.stderr, flush=True)
        text = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=job.get("max_tokens", 900),
            verbose=False,
            **extra
        )
        results.append({"id": item["id"], "text": text.strip()})

    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        json.dump(results, fh, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
