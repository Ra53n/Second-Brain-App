#!/usr/bin/env python3
"""Самотесты чистых функций тулчейна. Без сети, без моделей, без данных.

Проверяют то, что нельзя доказать калибровкой: что проверки действительно
ловят дефект, а не всегда возвращают «ок». Калибровка отвечает на вопрос
«не штрафуем ли мы правильный ответ», самотесты — «ловим ли неправильный».

    python3 selftest.py            exit≠0 при первом провале
"""

import sys
from typing import Callable, List, Tuple

import actionitem_checks as ac
import build_dataset
import build_meetings_dataset as bm
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


ACTION_REFERENCE = ('{"action_items": [{"assignee": "Industrial Designer", '
                    '"task": "prepare the working design", "due": "by the next meeting"}]}')
EMPTY_REFERENCE = '{"action_items": []}'


def test_actionitem_catches_defects() -> None:
    ok, _ = result(ac, ACTION_REFERENCE, ACTION_REFERENCE, "валидный JSON")
    check("поручения: эталон валиден", ok)

    ok, detail = result(ac, "Вот поручения: " + ACTION_REFERENCE, ACTION_REFERENCE, "без прозы")
    check("поручения: ловит прозу вокруг JSON", ok is False, detail)

    ok, detail = result(ac, "```json\n%s\n```" % ACTION_REFERENCE, ACTION_REFERENCE, "без прозы")
    check("поручения: ловит ```-обёртку", ok is False, detail)

    ok, detail = result(ac, "не JSON вовсе", ACTION_REFERENCE, "валидный JSON")
    check("поручения: ловит невалидный JSON", ok is False, detail)

    ok, detail = result(ac, '{"items": []}', EMPTY_REFERENCE, "валидный JSON")
    check("поручения: ловит чужой ключ верхнего уровня", ok is False, detail)

    # Главный дефект задачи: поручение, которого во фрагменте не было.
    ok, detail = result(ac, ACTION_REFERENCE, EMPTY_REFERENCE, "ничего не выдумано")
    check("поручения: ловит выдуманное поручение", ok is False, detail)

    ok, detail = result(ac, EMPTY_REFERENCE, ACTION_REFERENCE, "ничего не упущено")
    check("поручения: ловит пропущенное поручение", ok is False, detail)

    no_due = ACTION_REFERENCE.replace('"by the next meeting"', "null")
    ok, detail = result(ac, ACTION_REFERENCE, no_due, "срок не выдуман")
    check("поручения: ловит выдуманный срок", ok is False, detail)
    ok, _ = result(ac, no_due, ACTION_REFERENCE, "срок не выдуман")
    check("поручения: пропущенный срок не считается выдуманным", ok)

    wrong_actor = ACTION_REFERENCE.replace("Industrial Designer", "Marketing Expert")
    ok, detail = result(ac, wrong_actor, ACTION_REFERENCE, "ответственные")
    check("поручения: ловит чужого ответственного", ok is False, detail)

    ok, detail = result(ac, '{"action_items": [{"task": "prepare the working design"}]}',
                        ACTION_REFERENCE, "схема элементов")
    check("поручения: ловит неполную схему элемента", ok is False, detail)

    other_task = ACTION_REFERENCE.replace("prepare the working design",
                                          "order pizza for the office party")
    ok, detail = result(ac, other_task, ACTION_REFERENCE, "формулировка задачи")
    check("поручения: ловит подменённую задачу", ok is False, detail)

    ok, _ = result(ac, EMPTY_REFERENCE, EMPTY_REFERENCE, "ничего не выдумано")
    check("поручения: пустой эталон проходит сам себя", ok)


def test_meetings_builder_parses_actions() -> None:
    """Разбор предложения-поручения AMI: чистые функции сборщика."""
    parsed = bm.split_action("The industrial designer will work on the working design.")
    check("встречи: простое поручение разобрано",
          parsed == [{"assignee": "Industrial Designer",
                      "task": "work on the working design", "due": None}], str(parsed))

    parsed = bm.split_action(
        "The User Interface Designer and the Industrial Designer will build the prototype "
        "for the next meeting.")
    check("встречи: два исполнителя дают два поручения",
          parsed is not None and len(parsed) == 2
          and {item["assignee"] for item in parsed} == {"User Interface Designer",
                                                        "Industrial Designer"}, str(parsed))
    check("встречи: срок вынесен из формулировки",
          parsed is not None and all(item["due"] == "for the next meeting"
                                     and "next meeting" not in item["task"] for item in parsed),
          str(parsed))

    parsed = bm.split_action("The team will discuss the budget.")
    check("встречи: поручение всем — assignee None",
          parsed == [{"assignee": None, "task": "discuss the budget", "due": None}], str(parsed))

    parsed = bm.split_action("The Marketing Expert was instructed to check the evaluations.")
    check("встречи: пассив разобран",
          parsed == [{"assignee": "Marketing Expert",
                      "task": "check the evaluations", "due": None}], str(parsed))

    parsed = bm.split_action(
        "The Project Manager instructed the Industrial Designer to build the prototype.")
    check("встречи: «X поручил Y» даёт исполнителем Y",
          parsed is not None and len(parsed) == 1
          and parsed[0]["assignee"] == "Industrial Designer", str(parsed))

    check("встречи: заглушка *NA* — не поручение", bm.split_action("*NA*") == [])
    check("встречи: чужая формулировка не выдумывается",
          bm.split_action("Their personal coaches will give the rest of the information") is None)

    # Пунктуация в words.xml лежит отдельным элементом: если её приклеить через
    # пробел, транскрипт получит «слово . слово» и перевод споткнётся на строках.
    joined = bm.join_words(["Okay", "\x00.", "", "Right", "\x00."], 0, 4)
    check("встречи: пунктуация приклеена без пробела", joined == "Okay. Right.", repr(joined))


def main() -> int:
    tests: List[Callable[[], None]] = [
        test_actionitem_catches_defects,
        test_meetings_builder_parses_actions,
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
