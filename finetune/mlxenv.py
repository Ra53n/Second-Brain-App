#!/usr/bin/env python3
"""Поиск интерпретатора с mlx-lm.

Системный Python 3.9 не подходит — mlx требует 3.10+. Ищем в порядке:
переменная SB_FINETUNE_PYTHON, локальный .venv, текущий интерпретатор,
python3.12/3.11/3.10 из PATH.
"""

import os
import shutil
import subprocess
import sys
from typing import List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
VENV_PYTHON = os.path.join(HERE, ".venv", "bin", "python")

INSTALL_HINT = (
    "mlx-lm не найден. Поставь его в отдельный venv:\n"
    "    python3.12 -m venv finetune/.venv\n"
    "    finetune/.venv/bin/pip install -r finetune/requirements.txt\n"
    "Либо укажи готовый интерпретатор через SB_FINETUNE_PYTHON."
)


def candidates() -> List[str]:
    found = []
    explicit = os.environ.get("SB_FINETUNE_PYTHON")
    if explicit:
        found.append(explicit)
    if os.path.exists(VENV_PYTHON):
        found.append(VENV_PYTHON)
    found.append(sys.executable)
    for name in ("python3.12", "python3.11", "python3.10"):
        path = shutil.which(name)
        if path:
            found.append(path)
    seen, unique = set(), []
    for path in found:
        if path and path not in seen:
            seen.add(path)
            unique.append(path)
    return unique


def has_mlx(python: str) -> bool:
    try:
        result = subprocess.run(
            [python, "-c", "import mlx_lm"],
            capture_output=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def find_python(required: bool = True) -> Optional[str]:
    for python in candidates():
        if has_mlx(python):
            return python
    if required:
        sys.exit(INSTALL_HINT)
    return None


def mlx_version(python: str) -> str:
    result = subprocess.run(
        [python, "-c", "import mlx_lm; print(getattr(mlx_lm, '__version__', 'unknown'))"],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() or "unknown"


if __name__ == "__main__":
    python = find_python(required=False)
    if python:
        print("%s (mlx-lm %s)" % (python, mlx_version(python)))
    else:
        print(INSTALL_HINT)
        sys.exit(1)
