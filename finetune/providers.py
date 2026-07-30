#!/usr/bin/env python3
"""Провайдеры генерации: протокол → реестр → исполнитель.

Новый провайдер — это класс с методом `generate` и строка в REGISTRY;
вызывающий код (baseline.py) при этом не меняется. Сейчас реализация одна —
локальный mlx: облачный тюн для проекта закрыт, всё считается на своей машине.

    python3 providers.py            список провайдеров и готовность окружения
"""

import json
import os
import subprocess
import tempfile
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))


class ProviderError(RuntimeError):
    """Провайдер не смог выполнить генерацию; текст пригоден для показа человеку."""


class Provider:
    """Протокол: получить messages без ответа ассистента — вернуть текст ответа."""

    name = "base"
    default_model = ""

    def describe(self) -> str:
        raise NotImplementedError

    def available(self) -> bool:
        raise NotImplementedError

    def generate(self, items: List[Dict], model: str, max_tokens: int,
                 temperature: float, adapter: Optional[str] = None) -> Dict[str, str]:
        """items: [{"id": ..., "messages": [...]}] → {id: текст}."""
        raise NotImplementedError


class MLXProvider(Provider):
    """Локальный запуск через mlx-lm. Умеет подключать LoRA-адаптер."""

    name = "mlx"
    default_model = "mlx-community/Qwen2.5-7B-Instruct-4bit"

    def _python(self, required: bool = True) -> Optional[str]:
        import mlxenv

        return mlxenv.find_python(required=required)

    def available(self) -> bool:
        try:
            return self._python(required=False) is not None
        except Exception:
            return False

    def describe(self) -> str:
        python = self._python(required=False)
        if not python:
            return "mlx: нет интерпретатора с mlx-lm (см. requirements.txt)"
        import mlxenv

        return "mlx: %s (mlx-lm %s)" % (python, mlxenv.mlx_version(python))

    def generate(self, items, model, max_tokens, temperature, adapter=None):
        python = self._python()
        job = {
            "model": model or self.default_model,
            "adapter": adapter,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "items": items,
        }
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fh:
            json.dump(job, fh, ensure_ascii=False)
            job_path = fh.name
        out_path = job_path.replace(".json", ".out.json")
        try:
            result = subprocess.run([python, os.path.join(HERE, "_generate.py"), job_path, out_path])
            if result.returncode != 0:
                raise ProviderError("mlx-lm завершился с кодом %d" % result.returncode)
            with open(out_path, encoding="utf-8") as fh:
                return {item["id"]: item["text"] for item in json.load(fh)}
        finally:
            for path in (job_path, out_path):
                if os.path.exists(path):
                    os.unlink(path)


REGISTRY: Dict[str, Provider] = {p.name: p for p in (MLXProvider(),)}


def get(name: str) -> Provider:
    if name not in REGISTRY:
        raise ProviderError("Неизвестный провайдер %r. Доступны: %s"
                            % (name, ", ".join(sorted(REGISTRY))))
    return REGISTRY[name]


if __name__ == "__main__":
    for provider in REGISTRY.values():
        mark = "готов" if provider.available() else "НЕ готов"
        print("%-8s %-9s %s" % (provider.name, mark, provider.describe()))
