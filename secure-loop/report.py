#!/usr/bin/env python3
# report.py — сводка прогона Дня 14: out/run-log.jsonl (+ админка gateway, если задан
# GW_ADMIN_TOKEN) → out/summary.md. Только stdlib.

import json
import os
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOG_PATH = ROOT / "out/run-log.jsonl"
OUT_MD = ROOT / "out/summary.md"
GW_URL = os.environ.get("GW_URL", "").rstrip("/")
TOKEN = os.environ.get("GW_ADMIN_TOKEN", "")


def load_last_run():
    rows = [json.loads(l) for l in LOG_PATH.read_text(encoding="utf-8").splitlines()
            if l.strip()]
    starts = [i for i, r in enumerate(rows) if r["event"] == "run-start"]
    return rows[starts[-1]:] if starts else rows


def admin(path):
    req = urllib.request.Request(GW_URL + path,
                                 headers={"Authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def gateway_catches(calls):
    """Вызовы, где gateway что-то перехватил (маска/блок входа или не-pass выход)."""
    caught = []
    for c in calls:
        meta = c.get("meta") or {}
        if c.get("blocked") or meta.get("inputAction") not in (None, "allow") \
                or meta.get("outputVerdict") not in (None, "pass"):
            caught.append(c)
    return caught


def main():
    rows = load_last_run()
    calls = [r for r in rows if r["event"] == "gateway-call"]
    total_cost = sum((c.get("meta") or {}).get("costUsd") or 0 for c in calls)
    total_tokens = sum(((c.get("meta") or {}).get("usage") or {}).get("totalTokens") or 0
                       for c in calls)

    lines = ["# Сводка прогона secure-loop", ""]
    lines.append("Вызовов gateway: %d; токенов: %d; стоимость: $%.5f"
                 % (len(calls), total_tokens, total_cost))
    lines.append("")

    for done in (r for r in rows if r["event"] == "task-done"):
        tid = done["task"]
        trows = [r for r in rows if r.get("task") == tid]
        tcalls = [r for r in trows if r["event"] == "gateway-call"]
        lines.append("## %s — %s, кругов: %s" % (tid, done["status"], done["rounds"]))
        lines.append("")
        for v in (r for r in trows if r["event"] == "security-verdict"):
            if v["findings"]:
                items = "; ".join("[%s] строка %s: %s"
                                  % (f["severity"], f["line"], f["issue"])
                                  for f in v["findings"])
            else:
                items = "чисто"
            lines.append("- security step, круг %s: %s" % (v["round"], items))
        for b in (r for r in trows if r["event"] == "build" and not r["ok"]):
            lines.append("- сборка упала, круг %s" % b["round"])
        for c in gateway_catches(tcalls):
            meta = c.get("meta") or {}
            kinds = ", ".join(sorted({f.get("type", "?") for f in meta.get("findings") or []}))
            lines.append("- gateway перехват (%s, попытка %s): inputAction=%s%s, outputVerdict=%s"
                         % (c["stage"], c["attempt"], meta.get("inputAction"),
                            " [%s]" % kinds if kinds else "", meta.get("outputVerdict")))
        for w in done.get("warnings") or []:
            lines.append("- %s" % w)
        lines.append("")

    if GW_URL and TOKEN:
        try:
            stats = admin("/admin/stats")
            lines.append("## Админка gateway")
            lines.append("")
            lines.append("Статистика: %s" % json.dumps(stats, ensure_ascii=False))
            lines.append("")
            items = admin("/admin/interceptions?limit=30").get("items", [])
            lines.append("Последние перехваты (%d):" % len(items))
            for it in items:
                kinds = ", ".join(sorted({f.get("type", "?")
                                          for f in it.get("inputFindings") or []}))
                lines.append("- %s ip=%s inputAction=%s [%s] outputVerdict=%s"
                             % (it.get("createdAt"), it.get("ip"), it.get("inputAction"),
                                kinds, it.get("outputVerdict")))
        except Exception as e:  # админка недоступна — сводка по локальному логу всё равно полезна
            lines.append("Админка недоступна: %s" % e)

    OUT_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Сводка: %s" % OUT_MD)


if __name__ == "__main__":
    main()
