#!/usr/bin/env python3
"""Клиент запуска LoRA-тюна. Локальный аналог upload → create job → poll status.

    python3 train.py prepare        проверить окружение и данные (аналог upload file)
    python3 train.py start          запустить тюн фоном      (аналог create job)
    python3 train.py poll           ждать и показывать прогресс (аналог poll status)
    python3 train.py status         разовый снимок состояния
    python3 train.py logs [-n 40]   хвост лога

Состояние прогона лежит в runs/run.json, лог — в runs/train.log.
"""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from typing import Dict, List, Optional

import mlxenv

HERE = os.path.dirname(os.path.abspath(__file__))

# Пути раскрываются от --workdir: один и тот же клиент обслуживает несколько
# датасетов (посты в стиле канала, пост-процессор диктовки), каждый со своими
# data/, adapters/ и runs/.
DATA = RUNS = RUN_JSON = TRAIN_LOG = ADAPTERS = ""


def setup_paths(workdir: str) -> None:
    global DATA, RUNS, RUN_JSON, TRAIN_LOG, ADAPTERS
    root = workdir if os.path.isabs(workdir) else os.path.join(HERE, workdir)
    DATA = os.path.join(root, "data")
    RUNS = os.path.join(root, "runs")
    RUN_JSON = os.path.join(RUNS, "run.json")
    TRAIN_LOG = os.path.join(RUNS, "train.log")
    ADAPTERS = os.path.join(root, "adapters")

DEFAULT_MODEL = "mlx-community/Qwen2.5-7B-Instruct-4bit"
# Подобрано под 40 обучающих примеров на M2/16 GB: батч 1 и 8 слоёв держат пик
# памяти в пределах машины, 300 итераций — примерно 7-8 эпох.
DEFAULTS = {
    "iters": 300,
    "batch_size": 1,
    "num_layers": 8,
    "learning_rate": "1e-5",
    "max_seq_length": 2048,
    "steps_per_report": 10,
    "steps_per_eval": 50,
    "save_every": 50,
    # -1 = весь valid. При батче 1 любое конечное значение считало бы val loss
    # по горстке примеров, и сигнал переобучения тонул бы в шуме.
    "val_batches": -1,
}

TRAIN_LINE = re.compile(
    r"Iter\s+(\d+):\s+Train loss\s+([\d.]+).*?It/sec\s+([\d.]+)", re.I
)
VAL_LINE = re.compile(r"Iter\s+(\d+):\s+Val loss\s+([\d.]+)", re.I)


def parse_progress(line: str) -> Optional[Dict]:
    """Строка лога mlx-lm → прогресс. Чистая функция, используется и в poll, и в status."""
    match = VAL_LINE.search(line)
    if match:
        return {"kind": "val", "iter": int(match.group(1)), "val_loss": float(match.group(2))}
    match = TRAIN_LINE.search(line)
    if match:
        return {
            "kind": "train",
            "iter": int(match.group(1)),
            "train_loss": float(match.group(2)),
            "it_per_sec": float(match.group(3)),
        }
    return None


def lora_command(python: str) -> List[str]:
    """У mlx-lm две точки входа в зависимости от версии — определяем рабочую.

    `-u` обязателен: при редиректе в файл вывод буферизуется блоками, и poll
    показывал бы прогресс рывками по несколько минут.
    """
    for argv in ([python, "-u", "-m", "mlx_lm.lora"], [python, "-u", "-m", "mlx_lm", "lora"]):
        probe = subprocess.run(argv + ["--help"], capture_output=True)
        if probe.returncode == 0:
            return argv
    sys.exit("Не удалось запустить mlx_lm lora ни одним способом. Проверь версию mlx-lm.")


def model_cached(model: str) -> bool:
    folder = "models--" + model.replace("/", "--")
    cache = os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface")
    return os.path.isdir(os.path.join(cache, "hub", folder))


def load_run() -> Optional[Dict]:
    if not os.path.exists(RUN_JSON):
        return None
    with open(RUN_JSON, encoding="utf-8") as fh:
        return json.load(fh)


def is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def read_progress(limit: Optional[int] = None) -> Dict:
    """Сводка по логу: последняя итерация, последние train/val loss."""
    state: Dict = {"iter": 0, "train_loss": None, "val_loss": None, "it_per_sec": None}
    if not os.path.exists(TRAIN_LOG):
        return state
    with open(TRAIN_LOG, encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    for line in lines[-limit:] if limit else lines:
        progress = parse_progress(line)
        if not progress:
            continue
        state["iter"] = max(state["iter"], progress["iter"])
        if progress["kind"] == "train":
            state["train_loss"] = progress["train_loss"]
            state["it_per_sec"] = progress["it_per_sec"]
        else:
            state["val_loss"] = progress["val_loss"]
    return state


def cmd_prepare(args: argparse.Namespace) -> int:
    python = mlxenv.find_python()
    print("Интерпретатор: %s (mlx-lm %s)" % (python, mlxenv.mlx_version(python)))

    for name in ("train.jsonl", "valid.jsonl"):
        path = os.path.join(DATA, name)
        if not os.path.exists(path):
            sys.exit("Нет %s — запусти build_dataset.py и split.py" % path)

    validate_argv = [sys.executable, os.path.join(HERE, "validate.py"),
                     os.path.join(DATA, "train.jsonl"), os.path.join(DATA, "valid.jsonl")]
    if args.system:
        validate_argv += ["--system", args.system]
    if args.min_assistant is not None:
        validate_argv += ["--min-assistant", str(args.min_assistant)]
    check = subprocess.run(validate_argv)
    if check.returncode != 0:
        return check.returncode

    cached = model_cached(args.model)
    print("Модель %s: %s" % (args.model, "в кэше" if cached else "НЕ скачана (~4.3 ГБ)"))
    if not cached and args.download:
        print("Качаю модель, это надолго...")
        fetch = subprocess.run(
            [python, "-c", "from mlx_lm import load; load(%r)" % args.model]
        )
        if fetch.returncode != 0:
            return fetch.returncode
        print("Модель скачана")
    elif not cached:
        print("Запусти с --download, чтобы скачать заранее (иначе скачается при start)")

    print("Окружение готово")
    return 0


def cmd_start(args: argparse.Namespace) -> int:
    existing = load_run()
    if existing and is_alive(existing["pid"]):
        sys.exit("Прогон уже идёт (pid %d). Останови его или дождись конца." % existing["pid"])

    python = mlxenv.find_python()
    os.makedirs(RUNS, exist_ok=True)
    os.makedirs(ADAPTERS, exist_ok=True)

    config = dict(DEFAULTS)
    for key in config:
        override = getattr(args, key, None)
        if override is not None:
            config[key] = override

    argv = lora_command(python) + [
        "--model", args.model,
        "--train",
        "--data", DATA,
        "--adapter-path", ADAPTERS,
        "--iters", str(config["iters"]),
        "--batch-size", str(config["batch_size"]),
        "--num-layers", str(config["num_layers"]),
        "--learning-rate", str(config["learning_rate"]),
        "--max-seq-length", str(config["max_seq_length"]),
        "--steps-per-report", str(config["steps_per_report"]),
        "--steps-per-eval", str(config["steps_per_eval"]),
        "--save-every", str(config["save_every"]),
        "--val-batches", str(config["val_batches"]),
    ]

    log = open(TRAIN_LOG, "w", encoding="utf-8")
    log.write("$ %s\n" % " ".join(argv))
    log.flush()
    # Своя сессия: иначе тюн на час умрёт вместе с закрытым терминалом.
    process = subprocess.Popen(
        argv, stdout=log, stderr=subprocess.STDOUT, cwd=HERE, start_new_session=True
    )
    log.close()

    run = {
        "pid": process.pid,
        "model": args.model,
        "config": config,
        "argv": argv,
        "started_at": time.time(),
        "adapter_path": ADAPTERS,
        "log": TRAIN_LOG,
    }
    with open(RUN_JSON, "w", encoding="utf-8") as fh:
        json.dump(run, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print("Запущен тюн, pid %d" % process.pid)
    print("Лог: %s" % TRAIN_LOG)
    print("Следить: python3 train.py poll")
    return 0


def describe(run: Dict, state: Dict, alive: bool = True) -> str:
    total = run["config"]["iters"]
    done = state["iter"]
    parts = ["iter %d/%d" % (done, total)]
    if state["train_loss"] is not None:
        parts.append("train loss %.3f" % state["train_loss"])
    if state["val_loss"] is not None:
        parts.append("val loss %.3f" % state["val_loss"])
    if alive and state["it_per_sec"] and done < total:
        eta = (total - done) / state["it_per_sec"]
        parts.append("ETA %d мин" % max(1, round(eta / 60)))
    return ", ".join(parts)


def cmd_poll(args: argparse.Namespace) -> int:
    run = load_run()
    if not run:
        sys.exit("Нет запущенного прогона — сначала train.py start")

    last = ""
    while True:
        alive = is_alive(run["pid"])
        state = read_progress()
        line = describe(run, state, alive)
        if line != last:
            print(line, flush=True)
            last = line
        if not alive:
            break
        time.sleep(args.interval)

    adapter = os.path.join(run["adapter_path"], "adapters.safetensors")
    if os.path.exists(adapter):
        print("Готово. Адаптер: %s" % adapter)
        return 0
    print("Процесс завершился, но адаптера нет — смотри %s" % TRAIN_LOG, file=sys.stderr)
    return 1


def val_curve() -> List[Dict]:
    """Все замеры val loss из лога, по возрастанию итерации."""
    points = []
    if not os.path.exists(TRAIN_LOG):
        return points
    with open(TRAIN_LOG, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            progress = parse_progress(line)
            if progress and progress["kind"] == "val":
                points.append(progress)
    return points


def cmd_best(args: argparse.Namespace) -> int:
    """Выбор чекпоинта по val loss.

    На маленьком датасете train loss продолжает падать после того, как модель
    начала переобучаться, поэтому финальный адаптер почти никогда не лучший.
    """
    points = val_curve()
    if not points:
        sys.exit("В логе нет замеров val loss")

    for point in points:
        print("iter %3d: val loss %.3f" % (point["iter"], point["val_loss"]))

    best = min(points, key=lambda p: p["val_loss"])
    last = points[-1]
    print("\nЛучший: iter %d (val loss %.3f)" % (best["iter"], best["val_loss"]))
    if last["val_loss"] > best["val_loss"]:
        print("Переобучение: к iter %d val loss вырос до %.3f"
              % (last["iter"], last["val_loss"]))

    checkpoint = os.path.join(ADAPTERS, "%07d_adapters.safetensors" % best["iter"])
    if not os.path.exists(checkpoint):
        print("Чекпоинта %s нет — уменьши --save-every" % checkpoint, file=sys.stderr)
        return 1
    print("Чекпоинт: %s" % checkpoint)

    if args.install:
        final = os.path.join(ADAPTERS, "adapters.safetensors")
        backup = os.path.join(ADAPTERS, "adapters.final.safetensors")
        if os.path.exists(final) and not os.path.exists(backup):
            os.rename(final, backup)
            print("Финальный адаптер сохранён как %s" % backup)
        shutil.copyfile(checkpoint, final)
        print("Установлен как adapters.safetensors")
    else:
        print("Запусти с --install, чтобы сделать его основным адаптером")
    return 0


def cmd_status(_: argparse.Namespace) -> int:
    run = load_run()
    if not run:
        print("Прогонов не было")
        return 0
    alive = is_alive(run["pid"])
    state = read_progress()
    print("pid %d — %s" % (run["pid"], "идёт" if alive else "завершён"))
    print("модель %s" % run["model"])
    print(describe(run, state, alive))
    return 0


def cmd_logs(args: argparse.Namespace) -> int:
    if not os.path.exists(TRAIN_LOG):
        print("Лога нет")
        return 0
    with open(TRAIN_LOG, encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    sys.stdout.writelines(lines[-args.lines :])
    return 0


def cmd_stop(_: argparse.Namespace) -> int:
    run = load_run()
    if not run or not is_alive(run["pid"]):
        print("Нечего останавливать")
        return 0
    os.kill(run["pid"], signal.SIGTERM)
    for _attempt in range(30):
        if not is_alive(run["pid"]):
            print("Остановлен")
            return 0
        time.sleep(0.1)
    os.kill(run["pid"], signal.SIGKILL)
    print("Остановлен принудительно")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--workdir", default=".",
                        help="каталог датасета: внутри ожидаются data/, "
                             "туда же лягут adapters/ и runs/ (например dictation)")
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare", help="проверить окружение и данные")
    prepare.add_argument("--download", action="store_true", help="скачать модель заранее")
    prepare.add_argument("--system", default=None, help="эталонный system-промпт для валидатора")
    prepare.add_argument("--min-assistant", type=int, default=None,
                         help="нижний порог длины assistant для валидатора")
    prepare.set_defaults(func=cmd_prepare)

    start = sub.add_parser("start", help="запустить тюн фоном")
    for key, value in DEFAULTS.items():
        start.add_argument("--" + key.replace("_", "-"), dest=key, default=None,
                           type=type(value) if not isinstance(value, str) else str)
    start.set_defaults(func=cmd_start)

    poll = sub.add_parser("poll", help="ждать завершения, печатая прогресс")
    poll.add_argument("--interval", type=float, default=10.0)
    poll.set_defaults(func=cmd_poll)

    sub.add_parser("status", help="разовый снимок").set_defaults(func=cmd_status)
    sub.add_parser("stop", help="остановить прогон").set_defaults(func=cmd_stop)

    best = sub.add_parser("best", help="чекпоинт с минимальным val loss")
    best.add_argument("--install", action="store_true",
                      help="сделать его основным adapters.safetensors")
    best.set_defaults(func=cmd_best)

    logs = sub.add_parser("logs", help="хвост лога")
    logs.add_argument("-n", "--lines", type=int, default=40)
    logs.set_defaults(func=cmd_logs)

    args = parser.parse_args()
    setup_paths(args.workdir)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
