#!/usr/bin/env python3
"""render_diff.py — юнифайд-дифф → self-contained HTML для скриншота (задача 51).

Зачем свой рендер: страница должна открываться без интернета и без CDN
(diff2html и подобные тянут скрипты), а результат — годиться под скриншот
для сравнения двух генераций бенчмарка.

Использование: render_diff.py <patch> <html> <label>
"""

import html
import sys
from pathlib import Path

CSS = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { margin: 0; font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
       background: #fff; color: #1f2328; }
header { position: sticky; top: 0; z-index: 2; padding: 14px 20px;
         background: #f6f8fa; border-bottom: 1px solid #d0d7de; }
h1 { margin: 0 0 4px; font-size: 15px; font-weight: 600; }
.meta { font-size: 12px; color: #59636e; }
.wrap { padding: 16px 20px 60px; }
.file { margin: 0 0 18px; border: 1px solid #d0d7de; border-radius: 6px; overflow: hidden; }
.file > summary { padding: 8px 12px; background: #f6f8fa; cursor: pointer;
                  font-weight: 600; border-bottom: 1px solid #d0d7de; }
.file > summary::marker { color: #59636e; }
.counts { float: right; font-weight: 400; font-size: 12px; }
.add-n { color: #1a7f37; } .del-n { color: #cf222e; }
table { width: 100%; border-collapse: collapse; }
td { padding: 0 8px; vertical-align: top; white-space: pre-wrap;
     word-break: break-word; }
td.num { width: 1%; min-width: 44px; text-align: right; color: #8c959f;
         background: #f6f8fa; user-select: none; border-right: 1px solid #d8dee4; }
tr.add td { background: #e6ffec; } tr.add td.num { background: #ccffd8; }
tr.del td { background: #ffebe9; } tr.del td.num { background: #ffd7d5; }
tr.hunk td { background: #ddf4ff; color: #0550ae; font-size: 12px; }
tr.meta-row td { background: #f6f8fa; color: #59636e; font-size: 12px; }
@media (prefers-color-scheme: dark) {
  body { background: #0d1117; color: #e6edf3; }
  header, td.num, tr.meta-row td { background: #161b22; border-color: #30363d; }
  header { border-bottom-color: #30363d; }
  .file { border-color: #30363d; }
  .file > summary { background: #161b22; border-bottom-color: #30363d; }
  tr.add td { background: #12261e; } tr.add td.num { background: #1b4721; }
  tr.del td { background: #25171c; } tr.del td.num { background: #542426; }
  tr.hunk td { background: #121d2f; color: #4493f8; }
  .meta { color: #8d96a0; } td.num { color: #6e7681; }
}
"""


def split_files(patch_lines):
    """Режет патч на секции по 'diff --git'. Возвращает [(имя, [строки])]."""
    files, name, buf = [], None, []
    for line in patch_lines:
        if line.startswith("diff --git "):
            if name is not None:
                files.append((name, buf))
            # «diff --git a/путь b/путь» — берём часть после ' b/'
            name = line.split(" b/", 1)[1].strip() if " b/" in line else line[11:].strip()
            buf = []
        elif name is not None:
            buf.append(line)
    if name is not None:
        files.append((name, buf))
    return files


def render_file(name, lines):
    """Одна секция: <details> с таблицей строк и номерами из заголовков ханков."""
    rows, adds, dels = [], 0, 0
    old_n = new_n = 0
    for line in lines:
        esc = html.escape(line.rstrip("\n"))
        if line.startswith("@@"):
            # @@ -старая,N +новая,M @@ — забираем стартовые номера строк
            try:
                spec = line.split("@@")[1].strip()
                old_part, new_part = spec.split(" ")[0], spec.split(" ")[1]
                old_n = int(old_part[1:].split(",")[0])
                new_n = int(new_part[1:].split(",")[0])
            except (IndexError, ValueError):
                pass
            rows.append(f'<tr class="hunk"><td class="num"></td><td class="num"></td><td>{esc}</td></tr>')
        elif line.startswith(("index ", "--- ", "+++ ", "new file", "deleted file",
                              "similarity ", "rename ", "old mode", "new mode",
                              "Binary files")):
            rows.append(f'<tr class="meta-row"><td class="num"></td><td class="num"></td><td>{esc}</td></tr>')
        elif line.startswith("+"):
            adds += 1
            rows.append(f'<tr class="add"><td class="num"></td><td class="num">{new_n}</td><td>{esc}</td></tr>')
            new_n += 1
        elif line.startswith("-"):
            dels += 1
            rows.append(f'<tr class="del"><td class="num">{old_n}</td><td class="num"></td><td>{esc}</td></tr>')
            old_n += 1
        elif line.startswith("\\"):
            rows.append(f'<tr class="meta-row"><td class="num"></td><td class="num"></td><td>{esc}</td></tr>')
        else:
            rows.append(f'<tr><td class="num">{old_n}</td><td class="num">{new_n}</td><td>{esc}</td></tr>')
            old_n += 1
            new_n += 1
    counts = f'<span class="counts"><span class="add-n">+{adds}</span> <span class="del-n">−{dels}</span></span>'
    return (f'<details class="file" open><summary>{html.escape(name)}{counts}</summary>'
            f'<table>{"".join(rows)}</table></details>'), adds, dels


def main():
    if len(sys.argv) < 4:
        print("использование: render_diff.py <patch> <html> <label>", file=sys.stderr)
        return 1
    patch_path, out_path, label = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    lines = patch_path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)

    files = split_files(lines)
    body, total_add, total_del = [], 0, 0
    for name, chunk in files:
        chunk_html, adds, dels = render_file(name, chunk)
        body.append(chunk_html)
        total_add += adds
        total_del += dels

    if not files:
        body.append("<p>Дифф пуст: генерация не изменила ни одного файла.</p>")

    doc = (
        "<!doctype html><html lang='ru'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>Бенчмарк · {html.escape(label)}</title><style>{CSS}</style></head><body>"
        f"<header><h1>Бенчмарк · генерация {html.escape(label)}</h1>"
        f"<div class='meta'>файлов: {len(files)} · "
        f"<span class='add-n'>+{total_add}</span> · <span class='del-n'>−{total_del}</span></div></header>"
        f"<div class='wrap'>{''.join(body)}</div></body></html>"
    )
    out_path.write_text(doc, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
