#!/usr/bin/env python3
"""Сборка датасета из постов vault.

assistant всегда дословный текст автора; синтезируется только user.
Спецификации заданий лежат в corpus/posts.json, тексты читаются из vault
только на чтение.

    python3 build_dataset.py --map      разметка абзацев (для правки posts.json)
    python3 build_dataset.py            data/raw.jsonl + data/raw.meta.jsonl
"""

import argparse
import json
import os
import re
import sys
from typing import Dict, List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
BUSINESS_DIR = os.path.expanduser("~/Documents/Obsidian Vault/Second_Brain/Мои бизнес")
DEFAULT_VAULT = os.path.join(BUSINESS_DIR, "Площадки/Telegram/Посты в тг канал")

FRONTMATTER = re.compile(r"\A---\r?\n.*?\r?\n---\r?\n", re.DOTALL)
IMAGE_LINE = re.compile(r"\A\s*!\[\[[^\]]*\]\]\s*\Z")
MD_IMAGE_LINE = re.compile(r"\A\s*!\[[^\]]*\]\([^)]*\)\s*\Z")
WIKILINK = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")
HEADING = re.compile(r"\A\s*#{1,6}\s")


def clean(raw: str, article: bool = False) -> str:
    """Markdown-заметка → текст, как он ушёл бы читателю.

    Для статей дополнительно выбрасываются markdown-заголовки и картинки:
    фрагмент-эталон — это проза раздела, модель не должна учиться писать
    заголовочную обвязку."""
    text = FRONTMATTER.sub("", raw)
    kept = []
    for line in text.split("\n"):
        if IMAGE_LINE.match(line) or MD_IMAGE_LINE.match(line):
            continue
        if article and HEADING.match(line):
            continue
        kept.append(line.rstrip())
    text = "\n".join(kept)
    # Вложенная ссылка вида [[файл|подпись]] в канал уходит подписью.
    text = WIKILINK.sub(lambda m: m.group(2) or m.group(1), text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def paragraphs(text: str) -> List[str]:
    return [p for p in re.split(r"\n\s*\n", text) if p.strip()]


def load_post(vault: str, post: Dict) -> Tuple[str, List[str]]:
    # root=business — статьи и гайды, лежат выше папки постов канала.
    base = BUSINESS_DIR if post.get("root") == "business" else vault
    path = os.path.join(base, post["path"])
    if not os.path.exists(path):
        sys.exit("Не найден пост: %s" % path)
    with open(path, encoding="utf-8") as fh:
        text = clean(fh.read(), article=post.get("kind") == "article")
    return text, paragraphs(text)


def slice_text(paras: List[str], start: int, end: int) -> str:
    if start < 0 or end > len(paras) or start >= end:
        sys.exit("Некорректный срез [%d:%d] при %d абзацах" % (start, end, len(paras)))
    return "\n\n".join(paras[start:end])


def example(system: str, user: str, assistant: str) -> Dict:
    return {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
            {"role": "assistant", "content": assistant},
        ]
    }


def build(spec: Dict, system: str, vault: str) -> Tuple[List[Dict], List[Dict]]:
    rows, meta = [], []

    def add(task_type: str, user: str, assistant: str, post_id: str, suffix: str = "") -> None:
        rows.append(example(system, user, assistant))
        meta.append(
            {
                "id": "%s__%s%s" % (post_id, task_type, suffix),
                "source_post": post_id,
                "task_type": task_type,
            }
        )

    for post in spec["posts"]:
        pid = post["id"]
        full, paras = load_post(vault, post)

        if "brief" in post:
            add("brief_to_post", post["brief"], full, pid)
        if "draft" in post:
            add("draft_to_post", post["draft"], full, pid)
        if "hook" in post:
            add(
                "topic_to_hook",
                post["hook"]["ask"],
                slice_text(paras, 0, post["hook"]["paragraphs"]),
                pid,
            )
        for idx, section in enumerate(post.get("sections", [])):
            add(
                "section_to_fragment",
                section["ask"],
                slice_text(paras, section["from"], section["to"]),
                pid,
                suffix="_%d" % (idx + 1),
            )

    return rows, meta


def write_jsonl(path: str, rows: List[Dict]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", default=os.environ.get("SB_POSTS_DIR", DEFAULT_VAULT))
    parser.add_argument("--map", action="store_true", help="показать разметку абзацев")
    parser.add_argument("--out", default=os.path.join(HERE, "data"))
    args = parser.parse_args()

    with open(os.path.join(HERE, "corpus", "posts.json"), encoding="utf-8") as fh:
        spec = json.load(fh)
    with open(os.path.join(HERE, "system_prompt.txt"), encoding="utf-8") as fh:
        system = fh.read().strip()

    if args.map:
        for post in spec["posts"]:
            _, paras = load_post(args.vault, post)
            print("\n=== %s (%d абзацев) ===" % (post["id"], len(paras)))
            for i, para in enumerate(paras):
                head = para.replace("\n", " ⏎ ")[:95]
                print("%3d | %s" % (i, head))
        return

    rows, meta = build(spec, system, args.vault)
    os.makedirs(args.out, exist_ok=True)
    write_jsonl(os.path.join(args.out, "raw.jsonl"), rows)
    write_jsonl(os.path.join(args.out, "raw.meta.jsonl"), meta)

    by_type: Dict[str, int] = {}
    for item in meta:
        by_type[item["task_type"]] = by_type.get(item["task_type"], 0) + 1
    print("Собрано %d примеров из %d постов" % (len(rows), len(spec["posts"])))
    for task_type in sorted(by_type):
        print("  %-24s %d" % (task_type, by_type[task_type]))


if __name__ == "__main__":
    main()
