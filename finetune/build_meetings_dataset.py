#!/usr/bin/env python3
"""Сборка датасета «фрагмент встречи → поручения» из аннотаций AMI Meeting Corpus.

Здесь, в отличие от двух других датасетов, эталон не текст автора, а структура:
строгий JSON со списком поручений. Пустой список — полноправный эталон, он учит
модель не выдумывать задачу там, где её не давали.

Цепочка разметки корпуса:
    abstractive/<meet>.abssumm.xml   секция <actions> → предложения-поручения
    extractive/<meet>.summlink.xml   связь предложение ↔ реплика (dialogue act)
    dialogueActs/<meet>.<A>.dialog-act.xml   реплика → диапазон слов
    words/<meet>.<A>.words.xml       слова с таймингами
    corpusResources/meetings.xml     буква говорящего → роль (PM/ID/UI/ME)

    python3 build_meetings_dataset.py --out meetings
"""

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional, Set, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
NITE = "{http://nite.sourceforge.net/}"

ROLE_NAMES = {
    "PM": "Project Manager",
    "ID": "Industrial Designer",
    "UI": "User Interface Designer",
    "ME": "Marketing Expert",
}

HREF_RANGE = re.compile(r"([^#]+)#id\(([^)]+)\)(?:\.\.id\(([^)]+)\))?")

# Поручение в AMI — предложение вида «The industrial designer will work on X».
# Ответственный всегда именуется ролью, поэтому разбор правилами, а не моделью.
ACTOR = re.compile(
    r"\A\s*(?:the\s+)?(?P<actor>[a-z /,'-]+?)\s+"
    r"(?:will|is going to|are going to|should|shall|has to|have to|needs? to|"
    r"is to|are to|must)\s+(?P<task>.+?)\s*\Z",
    re.IGNORECASE | re.DOTALL,
)
# «When they return to their desks, they will …» — придаточное перед подлежащим
# сбивает разбор актора, а само поручение начинается после него.
LEAD_CLAUSE = re.compile(
    r"\A\s*(?:when|after|once|before|while|as soon as|upon)\b[^,]*,\s*",
    re.IGNORECASE,
)
# Аннотатор ставит эту заглушку, когда поручений на встрече не было.
EMPTY_MARKER = re.compile(r"\A\s*\*?NA\*?\s*\Z", re.IGNORECASE)
# Пассив и «X поручил Y сделать Z» — вторая по частоте форма после «X will do Y».
PASSIVE = re.compile(
    r"\A\s*(?:the\s+)?(?P<actor>[a-z /,'-]+?)\s+(?:was|were)\s+"
    r"(?:instructed|asked|told|assigned|requested)\s+"
    r"(?:to\s+|the\s+task\s+of\s+|with\s+)(?P<task>.+?)\s*\Z",
    re.IGNORECASE | re.DOTALL,
)
INSTRUCTED = re.compile(
    r"\A\s*(?:the\s+)?[a-z /,'-]+?\s+(?:instructed|asked|told)\s+"
    r"(?P<actor>[a-z /,'-]+?)\s+to\s+(?P<task>.+?)\s*\Z",
    re.IGNORECASE | re.DOTALL,
)
DUE = re.compile(
    r"\s*[,;]?\s*\b(?P<due>(?:by|before|until|for|after|in time for)\s+"
    r"(?:the\s+)?(?:next|upcoming|following|final|second|third|last)?\s*"
    r"(?:meeting|session|presentation|deadline|discussion|phase|round)[a-z ]*)\s*\Z",
    re.IGNORECASE,
)

ACTOR_ALIASES = {
    "project manager": ["Project Manager"],
    "industrial designer": ["Industrial Designer"],
    "user interface designer": ["User Interface Designer"],
    "user interface expert": ["User Interface Designer"],
    "user interface specialist": ["User Interface Designer"],
    "interface designer": ["User Interface Designer"],
    "interface specialist": ["User Interface Designer"],
    "interface expert": ["User Interface Designer"],
    "marketing expert": ["Marketing Expert"],
    "marketing executive": ["Marketing Expert"],
    "marketing manager": ["Marketing Expert"],
    "marketing specialist": ["Marketing Expert"],
    "industrial specialist": ["Industrial Designer"],
    "industrial deigner": ["Industrial Designer"],
    "industrial": ["Industrial Designer"],
    "interface designers": ["User Interface Designer"],
    "two designers": ["Industrial Designer", "User Interface Designer"],
    "designers": ["Industrial Designer", "User Interface Designer"],
    # Всей команде — исполнитель не назван поимённо, в эталоне это assignee: null.
    "team": [], "group": [], "team members": [], "whole team": [],
    "participants": [], "everyone": [], "they": [], "all members": [],
    "each team member": [], "every team member": [], "all team members": [],
    "some team members": [], "members": [], "all participants": [],
    "other team members": [], "rest of the team": [], "remaining members": [],
    "two members of the team": [], "two of the team members": [],
    "two team members": [], "both designers": ["Industrial Designer",
                                               "User Interface Designer"],
}


def load_roles(source: str) -> Dict[str, Dict[str, str]]:
    """observation → {буква говорящего: роль}. Без ролей транскрипт безымянный."""
    path = os.path.join(source, "corpusResources", "meetings.xml")
    roles: Dict[str, Dict[str, str]] = {}
    for meeting in ET.parse(path).getroot():
        observation = meeting.get("observation")
        if not observation:
            continue
        agents = {}
        for speaker in meeting:
            agent, role = speaker.get("nxt_agent"), speaker.get("role")
            if agent and role:
                agents[agent] = ROLE_NAMES.get(role, role)
        roles[observation] = agents
    return roles


def parse_words(path: str) -> Tuple[List[str], Dict[str, int], List[Optional[float]]]:
    """Слова файла в порядке следования, индекс по id и время начала каждого.

    Пунктуация возвращается отдельным элементом с ведущим маркером \\x00:
    склеить её с предыдущим словом умеет только тот, кто собирает текст реплики.
    """
    items: List[str] = []
    index: Dict[str, int] = {}
    times: List[Optional[float]] = []
    for element in ET.parse(path).getroot():
        wid = element.get(NITE + "id")
        tag = element.tag.split("}")[-1]
        if wid:
            index[wid] = len(items)
        raw = element.get("starttime")
        try:
            times.append(float(raw) if raw is not None else None)
        except ValueError:
            times.append(None)
        if tag == "w":
            text = (element.text or "").strip()
            items.append(("\x00" + text) if element.get("punc") == "true" else text)
        else:
            items.append("")
    return items, index, times


def join_words(items: List[str], start: int, end: int) -> str:
    out = ""
    for chunk in items[start:end + 1]:
        if not chunk:
            continue
        if chunk.startswith("\x00"):
            out += chunk[1:]
        else:
            out += (" " if out else "") + chunk
    return out.strip()


def parse_dacts(source: str, meeting: str, agent: str, items: List[str],
                index: Dict[str, int], times: List[Optional[float]]) -> Dict[str, Dict]:
    """Реплики говорящего: id → {text, start, agent}. Пустые реплики отбрасываются.

    `start` — время начала в секундах записи, а не позиция слова в файле: файлы
    говорящих независимы, и по позиции реплики четырёх участников перемешиваются
    (замерено на ES2003a: медианный сдвиг 48 реплик из 299).
    """
    path = os.path.join(source, "dialogueActs", "%s.%s.dialog-act.xml" % (meeting, agent))
    if not os.path.exists(path):
        return {}
    dacts: Dict[str, Dict] = {}
    for dact in ET.parse(path).getroot():
        did = dact.get(NITE + "id")
        if not did:
            continue
        first, last = None, None
        for child in dact:
            if not child.tag.endswith("child"):
                continue
            match = HREF_RANGE.match(child.get("href") or "")
            if not match:
                continue
            begin = index.get(match.group(2))
            finish = index.get(match.group(3) or match.group(2))
            if begin is None or finish is None:
                continue
            first = begin if first is None else min(first, begin)
            last = finish if last is None else max(last, finish)
        if first is None:
            continue
        text = join_words(items, first, last)
        if not text:
            continue
        started = next((times[i] for i in range(first, last + 1) if times[i] is not None), None)
        if started is None:
            continue
        dacts[did] = {"text": text, "start": started, "agent": agent}
    return dacts


def parse_actions(source: str, meeting: str) -> Dict[str, str]:
    """Предложения секции <actions> абстрактивного саммари: id → текст."""
    path = os.path.join(source, "abstractive", "%s.abssumm.xml" % meeting)
    if not os.path.exists(path):
        return {}
    sentences = {}
    for section in ET.parse(path).getroot():
        if section.tag.split("}")[-1] != "actions":
            continue
        for sentence in section:
            sid = sentence.get(NITE + "id")
            text = " ".join((sentence.text or "").split())
            if sid and text:
                sentences[sid] = text
    return sentences


def parse_summlink(source: str, meeting: str) -> Dict[str, List[str]]:
    """Предложение саммари → реплики, на которых оно основано."""
    path = os.path.join(source, "extractive", "%s.summlink.xml" % meeting)
    if not os.path.exists(path):
        return {}
    links: Dict[str, List[str]] = {}
    for link in ET.parse(path).getroot():
        extractive, abstractive = None, None
        for pointer in link:
            match = HREF_RANGE.match(pointer.get("href") or "")
            if not match:
                continue
            if pointer.get("role") == "extractive":
                extractive = match.group(2)
            elif pointer.get("role") == "abstractive":
                abstractive = match.group(2)
        if extractive and abstractive:
            links.setdefault(abstractive, []).append(extractive)
    return links


def resolve_actors(actor: str) -> Optional[List[Optional[str]]]:
    """Фраза-подлежащее → список исполнителей. None — не опознан; [None] — команда."""
    normalized = " ".join(actor.replace("the ", " ").split()).lower().strip(" ,")
    known = ACTOR_ALIASES.get(normalized)
    if known is not None:
        return list(known) or [None]
    parts = [part.strip(" ,") for part in re.split(r"\band\b|,", normalized) if part.strip(" ,")]
    if len(parts) < 2:
        return None
    resolved: List[Optional[str]] = []
    for part in parts:
        known = ACTOR_ALIASES.get(part)
        if known is None:
            return None
        resolved.extend(known or [None])
    # Дедуп с сохранением порядка: «ID and ID» из разных формулировок — один человек.
    unique: List[Optional[str]] = []
    for name in resolved:
        if name not in unique:
            unique.append(name)
    return unique


def split_action(sentence: str) -> Optional[List[Dict[str, Optional[str]]]]:
    """Предложение-поручение → список поручений.

    None — шаблон не подошёл (идёт в отчёт), [] — заглушка «поручений не было».
    Одно предложение даёт несколько поручений, когда исполнителей назвали двоих.
    """
    text = sentence.strip().rstrip(".")
    if EMPTY_MARKER.match(text):
        return []
    text = LEAD_CLAUSE.sub("", text)
    match = ACTOR.match(text) or PASSIVE.match(text) or INSTRUCTED.match(text)
    if not match:
        return None
    assignees = resolve_actors(match.group("actor"))
    if assignees is None:
        return None
    task = " ".join(match.group("task").split())
    due = None
    due_match = DUE.search(task)
    if due_match:
        due = " ".join(due_match.group("due").split())
        task = task[:due_match.start()].strip().rstrip(",;")
    if len(task.split()) < 2:
        return None
    return [{"assignee": assignee, "task": task, "due": due} for assignee in assignees]


def build_meeting(source: str, meeting: str, agents: Dict[str, str],
                  window: int, stride: float, report: List[str]) -> Tuple[List[Dict], int]:
    """Фрагменты одной встречи. Второе значение — сколько поручений не разобрано."""
    dacts: Dict[str, Dict] = {}
    for agent in sorted(agents):
        words_path = os.path.join(source, "words", "%s.%s.words.xml" % (meeting, agent))
        if not os.path.exists(words_path):
            continue
        items, index, times = parse_words(words_path)
        for did, dact in parse_dacts(source, meeting, agent, items, index, times).items():
            dact["role"] = agents[agent]
            dacts[did] = dact

    if not dacts:
        return [], 0

    # Реплики разных говорящих лежат в разных файлах со своей нумерацией слов:
    # общий порядок только по времени начала, иначе диалог перемешан.
    ordered = sorted(dacts.items(), key=lambda pair: (pair[1]["start"], pair[0]))

    # Поручения кучкуются в финале встречи, поэтому непересекающиеся окна дают
    # десяток фрагментов на весь корпус. Окна идут внахлёст: одна и та же
    # договорённость попадает в разное окружение — это разный вход, не дубль.
    bounds: List[Tuple[int, int]] = []
    start = 0
    while start < len(ordered):
        size, end = 0, start
        while end < len(ordered) and size < window:
            size += len(ordered[end][1]["text"].split())
            end += 1
        bounds.append((start, end))
        if end >= len(ordered):
            break
        step, size = start, 0
        while step < len(ordered) and size < window * stride:
            size += len(ordered[step][1]["text"].split())
            step += 1
        start = max(step, start + 1)

    unparsed = 0
    actions: List[Tuple[List[Dict], List[str]]] = []
    # Реплики поручений, которые не легли на шаблон. Окна вокруг них выбрасываем:
    # с пустым эталоном они учили бы модель молчать там, где поручение звучит.
    blocked: Set[str] = set()
    parsed_actions = parse_actions(source, meeting)
    links = parse_summlink(source, meeting)
    for sid, sentence in sorted(parsed_actions.items()):
        parsed = split_action(sentence)
        if parsed is None:
            unparsed += 1
            blocked.update(did for did in links.get(sid, []) if did in dacts)
            report.append("%s: не разобрано — %s" % (meeting, sentence))
            continue
        if not parsed:
            continue
        evidence = [did for did in links.get(sid, []) if did in dacts]
        if not evidence:
            # Поручение на встрече есть, а какие реплики его породили — неизвестно.
            # Отнести его не к чему, значит любой фрагмент этой встречи может
            # оказаться ложно-пустым. Встреча целиком в датасет не идёт.
            report.append("%s: нет привязки к репликам — %s" % (meeting, sentence))
            return [], unparsed
        actions.append((parsed, evidence))

    result = []
    for number, (start, end) in enumerate(bounds):
        inside = {did for did, _ in ordered[start:end]}
        if inside & blocked:
            continue
        found: List[Dict] = []
        ambiguous = False
        for parsed, evidence in actions:
            share = sum(1 for did in evidence if did in inside) / len(evidence)
            if share >= 0.5:
                # Копия на окно: одно и то же поручение попадает в несколько окон,
                # а assignee ниже правится по тексту конкретного окна.
                found.extend(dict(item) for item in parsed)
            elif share > 0:
                ambiguous = True
        # Обоснование поручения разорвано границей окна: эталон для такого фрагмента
        # не определён. Выбрасываем независимо от того, попали ли в окно другие
        # поручения: с ними эталон был бы неполным, без них — ложно пустым.
        if ambiguous:
            continue
        lines = ["%s: %s" % (dact["role"], dact["text"]) for _, dact in ordered[start:end]]
        text = "\n".join(lines)
        # Половины обоснований хватает, чтобы отнести поручение к окну, но исполнитель
        # мог быть назван во второй половине. System-промпт требует брать assignee
        # только из фрагмента — иначе эталон учил бы угадывать, кого не слышно.
        for item in found:
            if item["assignee"] and item["assignee"] not in text:
                item["assignee"] = None
        result.append({
            "id": "%s_%03d" % (meeting, number),
            "meeting": meeting,
            "text": text,
            "items": found,
        })
    return result, unparsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="meetings", help="каталог датасета")
    parser.add_argument("--window", type=int, default=220,
                        help="целевой размер фрагмента в словах")
    parser.add_argument("--stride", type=float, default=0.34,
                        help="шаг окна в долях его размера; 1.0 — без нахлёста")
    parser.add_argument("--positive-share", type=float, default=0.5,
                        help="доля фрагментов с поручениями после отсева")
    args = parser.parse_args()

    root = os.path.join(HERE, args.out)
    source = os.path.join(root, "source")
    if not os.path.isdir(os.path.join(source, "abstractive")):
        sys.stderr.write("Нет аннотаций AMI в %s (распакуйте архив корпуса).\n" % source)
        return 1

    system_path = os.path.join(root, "system_prompt.txt")
    if not os.path.exists(system_path):
        sys.stderr.write("Нет %s.\n" % system_path)
        return 1
    with open(system_path, encoding="utf-8") as fh:
        system = fh.read().strip()

    roles = load_roles(source)
    meetings = sorted(name.split(".")[0]
                      for name in os.listdir(os.path.join(source, "abstractive"))
                      if name.endswith(".abssumm.xml"))

    report: List[str] = []
    positives: List[Dict] = []
    negatives: List[Dict] = []
    unparsed_total = 0
    for meeting in meetings:
        agents = roles.get(meeting)
        if not agents:
            continue
        chunks, unparsed = build_meeting(source, meeting, agents, args.window,
                                         args.stride, report)
        unparsed_total += unparsed
        for chunk in chunks:
            (positives if chunk["items"] else negatives).append(chunk)

    # Отрицательных фрагментов в корпусе кратно больше. Оставляем столько, чтобы
    # баланс держался у заданной доли: иначе модель выучит «всегда пустой список».
    keep = int(len(positives) * (1 - args.positive_share) / max(args.positive_share, 1e-6))
    negatives.sort(key=lambda chunk: chunk["id"])
    step = max(1, len(negatives) // keep) if keep else len(negatives) + 1
    negatives = negatives[::step][:keep]

    # Классы чередуются ВНУТРИ каждой встречи и первым идёт фрагмент с поручением:
    # `baseline.py` берёт первые --count строк валидации, а сплит отбирает целые
    # встречи. При сортировке по id в замер попадали одни пустые фрагменты — он
    # мерил бы только умение молчать.
    by_meeting: Dict[str, Tuple[List[Dict], List[Dict]]] = {}
    for chunk in positives:
        by_meeting.setdefault(chunk["meeting"], ([], []))[0].append(chunk)
    for chunk in negatives:
        by_meeting.setdefault(chunk["meeting"], ([], []))[1].append(chunk)

    rows: List[Dict] = []
    # Встречи, где поручений не нашлось вовсе, уходят в конец: иначе они занимают
    # начало файла и снова уводят замер в одни пустые ответы.
    order = sorted(by_meeting, key=lambda name: (not by_meeting[name][0], name))
    for meeting in order:
        with_items, without = by_meeting[meeting]
        with_items.sort(key=lambda chunk: chunk["id"])
        without.sort(key=lambda chunk: chunk["id"])
        for pair in zip(with_items, without):
            rows.extend(pair)
        shared = min(len(with_items), len(without))
        rows.extend(with_items[shared:] + without[shared:])
    data_dir = os.path.join(root, "data")
    os.makedirs(data_dir, exist_ok=True)
    raw_path = os.path.join(data_dir, "raw.jsonl")
    meta_path = os.path.join(data_dir, "raw.meta.jsonl")
    with open(raw_path, "w", encoding="utf-8") as data_fh, \
            open(meta_path, "w", encoding="utf-8") as meta_fh:
        for chunk in rows:
            answer = json.dumps({"action_items": chunk["items"]}, ensure_ascii=False)
            record = {"messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": chunk["text"]},
                {"role": "assistant", "content": answer},
            ]}
            data_fh.write(json.dumps(record, ensure_ascii=False) + "\n")
            meta_fh.write(json.dumps({
                "id": chunk["id"],
                "source_post": chunk["meeting"],
                "task_type": "action_items",
                "lang": "en",
                "n_items": len(chunk["items"]),
            }, ensure_ascii=False) + "\n")

    print("встреч: %d, фрагментов: %d (с поручениями %d, без %d)"
          % (len(meetings), len(rows), len(positives), len(negatives)))
    print("поручений: %d, не разобрано: %d"
          % (sum(len(chunk["items"]) for chunk in positives), unparsed_total))
    print("записано: %s, %s" % (raw_path, meta_path))
    for line in report[:20]:
        sys.stderr.write(line + "\n")
    if len(report) > 20:
        sys.stderr.write("...ещё %d строк отчёта\n" % (len(report) - 20))
    return 0


if __name__ == "__main__":
    sys.exit(main())
