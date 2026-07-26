#!/usr/bin/env python3
"""smoke_report.py — результат прогона ui.sh run в self-contained HTML (задача 59, 61).

Скриншоты окна невозможны (kCGWindowSharingState=0), поэтому доказательство —
таблица PASS/FAIL шагов + AX-дамп сломанного экрана, а не картинка. Страница
без CDN и без сети — открывается локально в любой момент.

Одиночный сценарий (как раньше, задача 59):
    smoke_report.py --scenario <имя> --steps <tsv> --out <html> [--dump <файл>]

Сводный отчёт на несколько сценариев (задача 61) — группы --scenario/--steps/--dump
повторяются, ровно один --steps на каждый --scenario:
    smoke_report.py --out <html> [--tests-summary "<строка>"] \\
        --scenario a.txt --steps a.tsv [--dump a.dump] \\
        --scenario b.txt --steps b.tsv [--dump b.dump] ...
"""

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
section.scenario { margin: 0 0 28px; padding-bottom: 20px; border-bottom: 1px solid #d8dee4; }
section.scenario:last-child { border-bottom: none; padding-bottom: 0; margin-bottom: 0; }
section.scenario h2 { margin: 0 0 4px; font-size: 14px; font-weight: 600; }
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
  section.scenario { border-color: #30363d; }
}
"""

ROW_CLASS = {"PASS": "pass", "FAIL": "fail", "TIMEOUT": "fail", "SKIP": "skip"}


class ArgError(Exception):
    pass


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


def counts_of(steps):
    # SKIP не ломает шаг (безопасный клик пропущен намеренно) — считаем как pass,
    # той же логикой, что и ИТОГ: строка в ui.sh (fail — только FAIL/TIMEOUT).
    failed = sum(1 for status, _, _, _ in steps if status in ("FAIL", "TIMEOUT"))
    return len(steps) - failed, failed


def render_table_and_dump(steps, dump_text):
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
    return table, dump_html


def page(title, header_html, body_html):
    return (
        "<!doctype html><html lang='ru'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>{html.escape(title)}</title><style>{CSS}</style></head><body>"
        f"<header>{header_html}</header>"
        f"<div class='wrap'>{body_html}</div></body></html>"
    )


def render_single(scenario, steps, dump_text, timestamp):
    passed, failed = counts_of(steps)
    table, dump_html = render_table_and_dump(steps, dump_text)
    header = (
        f"<h1>Смоук · {html.escape(scenario)}</h1>"
        f"<div class='meta'>{html.escape(timestamp)} · <span class='counts'>"
        f"<span class='ok'>{passed} пройдено</span> / <span class='bad'>{failed} провалено</span>"
        "</span></div>"
    )
    return page(f"Смоук · {scenario}", header, table + dump_html)


def render_multi(scenarios, tests_summary, timestamp):
    total_pass = total_fail = total_steps = 0
    sections = []
    for scenario, steps, dump_text in scenarios:
        passed, failed = counts_of(steps)
        total_pass += passed
        total_fail += failed
        total_steps += len(steps)
        table, dump_html = render_table_and_dump(steps, dump_text)
        sections.append(
            f'<section class="scenario"><h2>{html.escape(scenario)}</h2>'
            f"<div class='meta'><span class='counts'>"
            f"<span class='ok'>{passed} пройдено</span> / <span class='bad'>{failed} провалено</span>"
            f"</span></div>{table}{dump_html}</section>"
        )

    tests_line = f"<div class='meta'>{html.escape(tests_summary)}</div>" if tests_summary else ""
    header = (
        "<h1>Смоук · сводный отчёт</h1>"
        f"<div class='meta'>{html.escape(timestamp)} · <span class='counts'>"
        f"{len(scenarios)} сценариев · {total_steps} шагов: "
        f"<span class='ok'>{total_pass} пройдено</span> / <span class='bad'>{total_fail} провалено</span>"
        "</span></div>"
        f"{tests_line}"
    )
    return page("Смоук · сводный отчёт", header, "".join(sections))


def parse_args(argv):
    """Ручной разбор вместо argparse: --scenario/--steps/--dump повторяются группами,
    и argparse не умеет выравнивать позиционно-связанные повторяемые флаги."""
    out = None
    tests_summary = None
    scenarios = []  # [{"scenario": str, "steps": str|None, "dump": str|None}]
    current = None
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok == "--out":
            if i + 1 >= len(argv):
                raise ArgError("--out требует значение")
            out = argv[i + 1]; i += 2
        elif tok == "--tests-summary":
            if i + 1 >= len(argv):
                raise ArgError("--tests-summary требует значение")
            tests_summary = argv[i + 1]; i += 2
        elif tok == "--scenario":
            if i + 1 >= len(argv):
                raise ArgError("--scenario требует значение")
            current = {"scenario": argv[i + 1], "steps": None, "dump": None}
            scenarios.append(current)
            i += 2
        elif tok == "--steps":
            if current is None:
                raise ArgError("--steps без предшествующего --scenario")
            if i + 1 >= len(argv):
                raise ArgError("--steps требует значение")
            current["steps"] = argv[i + 1]; i += 2
        elif tok == "--dump":
            if current is None:
                raise ArgError("--dump без предшествующего --scenario")
            if i + 1 >= len(argv):
                raise ArgError("--dump требует значение")
            current["dump"] = argv[i + 1]; i += 2
        else:
            raise ArgError(f"неизвестный аргумент: {tok}")

    if out is None:
        raise ArgError("нужен --out")
    if not scenarios:
        raise ArgError("нужен хотя бы один --scenario")
    for s in scenarios:
        if s["steps"] is None:
            raise ArgError(f"--scenario {s['scenario']} без --steps")

    return out, tests_summary, scenarios


def main():
    try:
        out, tests_summary, scenario_specs = parse_args(sys.argv[1:])
    except ArgError as e:
        print(f"ошибка аргументов: {e}", file=sys.stderr)
        return 1

    loaded = []
    for spec in scenario_specs:
        try:
            steps = parse_steps(Path(spec["steps"]))
        except OSError as e:
            print(f"не удалось прочитать {spec['steps']}: {e}", file=sys.stderr)
            return 1
        dump_text = None
        if spec["dump"] is not None:
            try:
                dump_text = Path(spec["dump"]).read_text(encoding="utf-8", errors="replace")
            except OSError:
                dump_text = None  # снимок не сохранился — отчёт всё равно должен собраться
        loaded.append((spec["scenario"], steps, dump_text))

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if len(loaded) == 1 and tests_summary is None:
        html_out = render_single(*loaded[0], timestamp)
    else:
        html_out = render_multi(loaded, tests_summary, timestamp)

    Path(out).write_text(html_out, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
