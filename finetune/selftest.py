#!/usr/bin/env python3
"""Самотесты чистых функций тулчейна. Без сети, без моделей, без данных.

Проверяют то, что нельзя доказать калибровкой: что проверки действительно
ловят дефект, а не всегда возвращают «ок». Калибровка отвечает на вопрос
«не штрафуем ли мы правильный ответ», самотесты — «ловим ли неправильный».

    python3 selftest.py            exit≠0 при первом провале
"""

import sys
from typing import Callable, List, Tuple

import build_dataset
import dictation_checks as dc
import style_checks as sc
import train

FAILURES: List[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        return
    FAILURES.append("%s%s" % (name, (" — " + detail) if detail else ""))


def result(checks, text: str, reference: str, wanted: str) -> Tuple[bool, str]:
    """Находит именованную проверку в наборе и отдаёт её вердикт."""
    for check_name, ok, detail in checks.run_checks(text, reference):
        if check_name.startswith(wanted):
            return ok, detail
    raise AssertionError("нет проверки %r" % wanted)


REFERENCE = (
    "Привет! Появились новые вводные. Нам нужно проверить сборку в CI, "
    "потому что артефакты собираются, но тесты падают на 3 из 40 кейсов."
)


def test_dictation_catches_defects() -> None:
    ok, _ = result(dc, REFERENCE, REFERENCE, "похожесть")
    check("диктовка: эталон похож сам на себя", ok)

    ok, detail = result(dc, "Совершенно другой текст про погоду и котиков.", REFERENCE, "похожесть")
    check("диктовка: ловит переписанный текст", ok is False, detail)

    ok, detail = result(dc, "Вот исправленный текст: " + REFERENCE, REFERENCE, "без преамбулы")
    check("диктовка: ловит преамбулу", ok is False, detail)

    ok, detail = result(dc, "```\n%s\n```" % REFERENCE, REFERENCE, "без обёртки")
    check("диктовка: ловит блок кода", ok is False, detail)

    ok, detail = result(dc, REFERENCE.replace("CI", "си-ай"), REFERENCE, "термины латиницей")
    check("диктовка: ловит потерю термина", ok is False, detail)

    ok, detail = result(dc, REFERENCE.replace("3 из 40", "5 из 40"), REFERENCE, "числа")
    check("диктовка: ловит искажение числа", ok is False, detail)

    no_punct = REFERENCE.replace(",", "").replace(".", "").replace("!", "")
    ok, detail = result(dc, no_punct, REFERENCE, "пунктуация")
    check("диктовка: ловит отсутствие пунктуации", ok is False, detail)

    ok, detail = result(dc, "## Заголовок\n\n" + REFERENCE, REFERENCE, "не добавляет разметку")
    check("диктовка: ловит добавленную разметку", ok is False, detail)

    ok, _ = result(dc, REFERENCE, REFERENCE, "длина")
    check("диктовка: длина эталона в допуске", ok)
    ok, detail = result(dc, REFERENCE * 3, REFERENCE, "длина")
    check("диктовка: ловит раздувание", ok is False, detail)


POST = "🚂 Заголовок поста\n\nЯ попробовал новый инструмент и вот что вышло. Мне понравилось."


def test_style_catches_defects() -> None:
    ok, detail = result(sc, POST.replace("🚂 ", ""), POST, "эмодзи")
    check("стиль: ловит потерю эмодзи в заголовке", ok is False, detail)

    ok, detail = result(sc, POST + "\n\n### Подзаголовок\n\nтекст", POST, "без ##")
    check("стиль: ловит markdown-подзаголовок", ok is False, detail)

    ok, detail = result(sc, POST + "\n\n✅ Пункт", POST, "без ✅")
    check("стиль: ловит галочки", ok is False, detail)

    ok, detail = result(sc, "В современном мире важно отметить, что это так.", POST, "без AI-клише")
    check("стиль: ловит клише", ok is False, detail)

    ok, _ = result(sc, POST, POST, "эмодзи")
    check("стиль: эталон проходит проверку эмодзи", ok)


def test_log_parser() -> None:
    line = ("Iter 10: Train loss 2.053, Learning Rate 1.000e-05, It/sec 0.088, "
            "Tokens/sec 73.839, Trained Tokens 8356, Peak mem 11.110 GB")
    parsed = train.parse_progress(line)
    check("лог: train-строка распознана", parsed is not None)
    if parsed:
        check("лог: номер итерации", parsed["iter"] == 10, str(parsed))
        check("лог: train loss", abs(parsed["train_loss"] - 2.053) < 1e-6, str(parsed))
        check("лог: скорость", abs(parsed["it_per_sec"] - 0.088) < 1e-6, str(parsed))

    parsed = train.parse_progress("Iter 50: Val loss 1.212, Val took 15.818s")
    check("лог: val-строка распознана", parsed is not None and parsed["kind"] == "val")
    if parsed:
        check("лог: val loss", abs(parsed["val_loss"] - 1.212) < 1e-6, str(parsed))

    for junk in ("", "Loading datasets", "Iter: непонятно", "Peak mem 11.110 GB"):
        check("лог: мусор не распознан как прогресс (%r)" % junk[:20],
              train.parse_progress(junk) is None)


def test_markdown_cleaner() -> None:
    raw = (
        "---\ntype: пост\nstatus: черновик\n---\n\n"
        "🚂 Заголовок\n\n"
        "![[Pasted image 20250220211627.png]]\n\n"
        "Текст со ссылкой [[Заметка|подписью]] внутри.\n\n\n\n"
        "Хвост.\n"
    )
    cleaned = build_dataset.clean(raw)
    check("чистка: убран фронтматтер", "type: пост" not in cleaned, cleaned[:40])
    check("чистка: убрана картинка", "Pasted image" not in cleaned)
    check("чистка: wikilink стал подписью", "подписью" in cleaned and "[[" not in cleaned)
    check("чистка: схлопнуты пустые строки", "\n\n\n" not in cleaned)
    check("чистка: текст сохранён", cleaned.startswith("🚂 Заголовок") and cleaned.endswith("Хвост."))

    article = build_dataset.clean("## Раздел\n\nПроза раздела.\n", article=True)
    check("чистка: у статьи снят заголовок", article == "Проза раздела.", repr(article))

    paras = build_dataset.paragraphs("Первый\n\nВторой\n\n\nТретий")
    check("чистка: разбивка на абзацы", paras == ["Первый", "Второй", "Третий"], str(paras))


def main() -> int:
    tests: List[Callable[[], None]] = [
        test_dictation_catches_defects,
        test_style_catches_defects,
        test_log_parser,
        test_markdown_cleaner,
    ]
    for test in tests:
        test()

    if FAILURES:
        print("ПРОВАЛЕНО %d:" % len(FAILURES), file=sys.stderr)
        for failure in FAILURES:
            print("  " + failure, file=sys.stderr)
        return 1
    print("OK — все самотесты пройдены")
    return 0


if __name__ == "__main__":
    sys.exit(main())
