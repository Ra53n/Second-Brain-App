#!/usr/bin/env python3
"""smoke_report.py — результат прогона ui.sh run в self-contained HTML (задача 59).

Скриншоты окна невозможны (kCGWindowSharingState=0), поэтому доказательство —
таблица PASS/FAIL шагов + AX-дамп сломанного экрана, а не картинка. Страница
без CDN и без сети — открывается локально в любой момент.

Использование:
    smoke_report.py --scenario <имя> --steps <tsv> --out <html> [--dump <файл>]
"""

import argparse
import html
import sys
from datetime import datetime
from pathlib import Path

CSS = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { margin: 0; font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
       background: #fff; color: #1f2328; }
header { padding: 14px 20px; background: #f6f8fa; border-bottom: 1px solid #d0d7de; }
h1 { margin: 0 0 4px; font-size: 15px; font-weight: 600; }
.meta { font-size: 12px; color: #59636e; }
.counts { font-weight: 600; }
.ok { color: #1a7f37; } .bad { color: #cf222e; }
.wrap { padding: 16px 20px 60px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th, td { padding: 6px 10px; text-align: left; vertical-align: top;
         white-space: pre-wrap; word-break: break-word; border-bottom: 1px solid #d8dee4; }
th { background: #f6f8fa; font-weight: 600; position: sticky; top: 0; }
td.status { font-weight: 600; white-space: nowrap; }
tr.pass td { background: #e6ffec; }
tr.fail td { background: #ffebe9; }
tr.skip td { color: #59636e; background: #f6f8fa; }
details.dump { margin-top: 18px; border: 1px solid #d0d7de; border-radius: 6px; overflow: hidden; }
details.dump > summary { padding: 8px 12px; background: #f6f8fa; cursor: pointer; font-weight: 600; }
details.dump pre { margin: 0; padding: 12px; font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
                    white-space: pre-wrap; word-break: break-word; }
@media (prefers-color-scheme: dark) {
  body { background: #0d1117; color: #e6edf3; }
  header { background: #161b22; border-color: #30363d; }
  .meta { color: #8d96a0; }
  th { background: #161b22; border-color: #30363d; }
  td { border-color: #30363d; }
  tr.pass td { background: #12261e; }
  tr.fail td { background: #25171c; }
  tr.skip td { background: #161b22; color: #8d96a0; }
  details.dump { border-color: #30363d; }
  details.dump > summary { background: #161b22; }
}
"""

ROW_CLASS = {"PASS": "pass", "FAIL": "fail", "TIMEOUT": "fail", "SKIP": "skip"}


def parse_steps(path):
    """TSV status⇥action⇥arg⇥output → список кортежей. Пустые строки пропускаются,
    короткие строки дополняются пустыми полями — битый вход не должен ронять рендер."""
    steps = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        parts = raw.split("\t")
        if len(parts) < 4:
            parts += [""] * (4 - len(parts))
        status, action, arg = parts[0].strip(), parts[1], parts[2]
        output = "\t".join(parts[3:])
        steps.append((status, action, arg, output))
    return steps


def render_row(status, action, arg, output):
    cls = ROW_CLASS.get(status, "")
    cells = "".join(f"<td>{html.escape(c)}</td>" for c in (action, arg, output))
    return f'<tr class="{cls}"><td class="status">{html.escape(status)}</td>{cells}</tr>'


def render(scenario, steps, dump_text):
    # SKIP не ломает шаг (безопасный клик пропущен намеренно) — считаем как pass,
    # той же логикой, что и ИТОГ: строка в ui.sh (fail — только FAIL/TIMEOUT).
    failed = sum(1 for status, _, _, _ in steps if status in ("FAIL", "TIMEOUT"))
    passed = len(steps) - failed
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    rows = "".join(render_row(*step) for step in steps)
    table = (
        "<table><thead><tr><th>Статус</th><th>Шаг</th><th>Аргумент</th>"
        f"<th>Результат</th></tr></thead><tbody>{rows}</tbody></table>"
    )
    if not steps:
        table += "<p>Шагов нет: сценарий пуст.</p>"

    dump_html = ""
    if dump_text is not None:
        dump_html = (
            '<details class="dump"><summary>AX-дерево сломанного экрана</summary>'
            f"<pre>{html.escape(dump_text)}</pre></details>"
        )

    return (
        "<!doctype html><html lang='ru'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>Смоук · {html.escape(scenario)}</title><style>{CSS}</style></head><body>"
        f"<header><h1>Смоук · {html.escape(scenario)}</h1>"
        f"<div class='meta'>{html.escape(timestamp)} · <span class='counts'>"
        f"<span class='ok'>{passed} пройдено</span> / <span class='bad'>{failed} провалено</span>"
        "</span></div></header>"
        f"<div class='wrap'>{table}{dump_html}</div></body></html>"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", required=True, help="имя сценария (в заголовок отчёта)")
    parser.add_argument("--steps", required=True, type=Path, help="TSV: status⇥action⇥arg⇥output")
    parser.add_argument("--out", required=True, type=Path, help="куда писать HTML")
    parser.add_argument("--dump", type=Path, help="AX-дамп сломанного экрана (опционально)")
    args = parser.parse_args()

    try:
        steps = parse_steps(args.steps)
    except OSError as e:
        print(f"не удалось прочитать {args.steps}: {e}", file=sys.stderr)
        return 1

    dump_text = None
    if args.dump is not None:
        try:
            dump_text = args.dump.read_text(encoding="utf-8", errors="replace")
        except OSError:
            dump_text = None  # снимок не сохранился — отчёт всё равно должен собраться

    args.out.write_text(render(args.scenario, steps, dump_text), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
