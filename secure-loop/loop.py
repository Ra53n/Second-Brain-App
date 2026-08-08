#!/usr/bin/env python3
# loop.py — execution loop Дня 14 (задача 104): генерация кода через LLM Gateway →
# swift build → security review вторым вызовом gateway → коммит в одноразовый git.
# Только stdlib; все LLM-вызовы идут на $GW_URL/chat, напрямую в DeepSeek не ходим.

import json
import os
import random
import re
import shutil
import string
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import prompts
import sbtasks

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
WORK = OUT / "work"
LOG_PATH = OUT / "run-log.jsonl"

GW_URL = os.environ.get("GW_URL", "").rstrip("/")
THROTTLE = float(os.environ.get("GW_THROTTLE", "4"))  # rate limit 20/мин → держим ~15/мин
MAX_ROUNDS = 4
HTTP_TIMEOUT = 300  # у gateway свой 90-с таймаут к LLM плюс ретраи
DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

# Плантованные фейки для демонстрации input guard: генерятся на рантайме,
# в git не попадают, в локальных логах маскируются.
planted = []

FAKE_EMAIL = "irina.petrova@corp-mail.example"
STATUS_ENDPOINT = "http://api.internal.example/status"


def fake_aws_key():
    return "AKIA" + "".join(random.choices(string.ascii_uppercase + string.digits, k=16))


def mask_local(text):
    for s in planted:
        text = text.replace(s, "[PLANTED]")
    return text


def log_event(event, **kw):
    row = {"ts": datetime.now(timezone.utc).isoformat(), "event": event}
    row.update(kw)
    with LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


# ── Gateway ────────────────────────────────────────────────────────────────────

def gw_chat(prompt, task_id, stage, attempt):
    """Один вызов gateway с ретраями: 429 → Retry-After, 5xx/сеть → backoff."""
    body = json.dumps({"prompt": prompt}).encode("utf-8")
    last_err = "нет ответа"
    for retry in range(5):
        if retry == 0:
            time.sleep(THROTTLE)
        req = urllib.request.Request(
            GW_URL + "/chat", data=body,
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            log_event("gateway-call", task=task_id, stage=stage, attempt=attempt,
                      prompt_preview=mask_local(prompt)[:400],
                      blocked=data.get("blocked"), warning=data.get("warning"),
                      answer_preview=mask_local(data.get("answer", ""))[:400],
                      meta=data.get("meta"))
            return data
        except urllib.error.HTTPError as e:
            payload = e.read().decode("utf-8", "replace")[:300]
            last_err = "HTTP %d: %s" % (e.code, payload)
            if e.code == 429:
                try:
                    delay = int(e.headers.get("Retry-After") or 20)
                except ValueError:  # Retry-After может быть HTTP-датой
                    delay = 20
                time.sleep(delay)
                continue
            if e.code >= 500:
                time.sleep(5 * (retry + 1))
                continue
            break  # прочие 4xx (пустой промпт, суточный лимит) ретраить бессмысленно
        # OSError покрывает URLError и socket.timeout: на Python 3.9 socket.timeout
        # ещё не алиас TimeoutError, голым он ронял бы весь прогон.
        except (OSError, json.JSONDecodeError) as e:
            last_err = str(e)
            time.sleep(5 * (retry + 1))
    log_event("gateway-error", task=task_id, stage=stage, attempt=attempt, error=last_err)
    raise RuntimeError("gateway недоступен (%s): %s" % (stage, last_err))


# ── Разбор ответа генерации ────────────────────────────────────────────────────

CODE_RE = re.compile(r"```swift\s*\n(.*?)```", re.DOTALL)
ANY_CODE_RE = re.compile(r"```[a-zA-Z]*\s*\n(.*?)```", re.DOTALL)


def extract_swift(answer):
    """(код, оборван_ли): открытый фенс без закрытия = ответ обрезан по maxTokens."""
    m = CODE_RE.search(answer) or ANY_CODE_RE.search(answer)
    if m:
        return m.group(1).strip() + "\n", False
    return None, "```" in answer


# ── Сборка ────────────────────────────────────────────────────────────────────

def swift_build():
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    try:
        p = subprocess.run(["swift", "build"], cwd=WORK, env=env,
                           capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return False, "swift build превысил таймаут 600 с"
    out = (p.stdout + p.stderr).strip()
    if p.returncode == 0:
        return True, ""
    errors = "\n".join(l for l in out.splitlines() if "error:" in l)
    return False, (errors or out)[-2000:]


# ── Security step ─────────────────────────────────────────────────────────────

SEVERITIES = ("critical", "high", "medium", "low")


def parse_verdict(answer):
    """JSON-вердикт из ответа модели; None — не распарсился."""
    start, end = answer.find("{"), answer.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(answer[start:end + 1])
    except json.JSONDecodeError:
        return None
    raw = data.get("findings")
    if not isinstance(raw, list):
        return None
    findings = []
    for f in raw:
        if not isinstance(f, dict):
            continue
        sev = str(f.get("severity", "")).lower()
        if sev not in SEVERITIES:
            sev = "high"  # незнакомое значение «из будущего» → безопасный режим
        findings.append({"severity": sev, "line": f.get("line"),
                         "issue": str(f.get("issue", ""))})
    return findings


def security_review(code, task, round_):
    """Вердикт security step. Возвращает (findings, gateway_blocked)."""
    numbered = "\n".join("%3d: %s" % (i + 1, l) for i, l in enumerate(code.splitlines()))
    prompt = prompts.SECURITY_REVIEW.format(filename=task["file"], code=numbered)
    for attempt in (1, 2):
        resp = gw_chat(prompt, task["id"], "security", round_)
        if resp.get("blocked"):
            return [], True
        findings = parse_verdict(resp.get("answer", ""))
        if findings is not None:
            return findings, False
        log_event("verdict-unparsed", task=task["id"], round=round_, attempt=attempt)
        prompt = prompt + "\n" + prompts.JSON_RETRY
    # Дважды не распарсился — код не принимаем и круги на бессмысленный фидбек не жжём
    return None, False


# ── Sandbox ───────────────────────────────────────────────────────────────────

def git(*args):
    subprocess.run(["git"] + list(args), cwd=WORK, check=True,
                   capture_output=True, text=True)


def setup_work():
    OUT.mkdir(exist_ok=True)
    if WORK.exists():
        shutil.rmtree(WORK)
    shutil.copytree(ROOT / "sandbox", WORK)
    key = fake_aws_key()
    planted.append(key)
    config = (
        "// Конфиг sandbox: значения тестовые, файл генерится харнесом и в git не попадает.\n"
        "public enum AppConfig {\n"
        '    public static let awsBackupKey = "%s"\n'
        '    public static let supportEmail = "%s"\n'
        '    public static let statusEndpoint = "%s"\n'
        "}\n" % (key, FAKE_EMAIL, STATUS_ENDPOINT)
    )
    (WORK / "Sources/Sandbox/AppConfig.swift").write_text(config, encoding="utf-8")
    git("init", "-q")
    git("config", "user.name", "secure-loop")
    git("config", "user.email", "secure-loop@localhost")
    git("add", "-A")
    git("commit", "-qm", "скелет sandbox + тестовый конфиг")


def sandbox_context():
    parts = []
    for p in sorted((WORK / "Sources/Sandbox").glob("*.swift")):
        parts.append("--- %s ---\n%s" % (p.name, p.read_text(encoding="utf-8")))
    return "\n".join(parts)


# ── Цикл одной задачи ─────────────────────────────────────────────────────────

def run_task(task):
    print("→ %s: %s" % (task["id"], task["title"]))
    followup = ""
    status = "stopped-limit"
    warnings = []
    round_ = 0
    for round_ in range(1, MAX_ROUNDS + 1):
        base = prompts.GENERATION_HEADER.format(task=task["prompt"],
                                                context=sandbox_context())
        resp = gw_chat(base + followup, task["id"], "generate", round_)
        if resp.get("blocked"):
            status = "gateway-blocked"
            break
        code, truncated = extract_swift(resp.get("answer", ""))
        if code is None:
            if truncated:
                followup = ("\n\nТвой прошлый ответ оборвался до закрытия блока кода "
                            "(лимит токенов). Верни файл целиком, но компактно: "
                            "без комментариев и лишних пустых строк.")
            else:
                followup = ("\n\nВ прошлом ответе не было блока ```swift```. "
                            "Верни ровно один блок кода.")
            log_event("no-code", task=task["id"], round=round_, truncated=truncated)
            continue
        (WORK / "Sources/Sandbox" / task["file"]).write_text(code, encoding="utf-8")
        ok, errors = swift_build()
        log_event("build", task=task["id"], round=round_, ok=ok,
                  errors=errors[:1000] if errors else None)
        if not ok:
            print("  круг %d: сборка упала" % round_)
            followup = prompts.BUILD_FIX_FOOTER.format(
                filename=task["file"], errors=errors, previous=code)
            continue
        findings, gw_blocked = security_review(code, task, round_)
        if gw_blocked:
            status = "gateway-blocked"
            break
        if findings is None:
            status = "verdict-unparsed"
            break
        log_event("security-verdict", task=task["id"], round=round_, findings=findings)
        blocking = [f for f in findings if f["severity"] in ("critical", "high")]
        minor = [f for f in findings if f["severity"] in ("medium", "low")]
        if blocking:
            print("  круг %d: security NO-GO — %d critical/high" % (round_, len(blocking)))
            issues = "\n".join("- исправь: %s (строка %s, %s)"
                               % (f["issue"], f["line"], f["severity"]) for f in blocking)
            followup = prompts.SECURITY_FIX_FOOTER.format(
                filename=task["file"], issues=issues, previous=code)
            continue
        for f in minor:
            w = "WARNING [%s] %s:%s — %s" % (f["severity"], task["file"], f["line"], f["issue"])
            warnings.append(w)
            print("  " + w)
        git("add", "Sources/Sandbox/" + task["file"])
        git("commit", "-qm", "%s: %s (круг %d)" % (task["id"], task["title"], round_))
        status = "committed"
        break
    summary = {"task": task["id"], "status": status, "rounds": round_,
               "warnings": warnings}
    log_event("task-done", **summary)
    print("  итог: %s (кругов: %d)" % (status, round_))
    return summary


def main():
    if not GW_URL:
        sys.exit("Задай GW_URL, пример: https://<VPS_HOST>/gw")
    only = sys.argv[1] if len(sys.argv) > 1 else None
    tasks = [t for t in sbtasks.TASKS if only in (None, t["id"])]
    if not tasks:
        sys.exit("Нет задачи с id %s" % only)
    setup_work()
    log_event("run-start", tasks=[t["id"] for t in tasks])
    try:
        results = [run_task(t) for t in tasks]
    except RuntimeError as e:
        sys.exit("Стоп: %s" % e)
    log_event("run-end", results=results)
    print("\nИтого: " + ", ".join("%s=%s" % (r["task"], r["status"]) for r in results))


if __name__ == "__main__":
    main()
