# Задача 42: breadcrumb-путь заметки и роутинг по папкам

## Цель

Открыв заметку, пользователь видит, в какой папке vault она лежит: над
редактором — полоска пути (breadcrumb) в стиле Obsidian/Finder. Клик по
сегменту-папке «проваливается» в неё: справа открывается содержимое папки
(дальше можно кликать, как в колонке Finder), а дерево слева раскрывает и
подсвечивает её.

## Зависимости

02 (vault-ядро: дерево, VaultManager), 03 (редактор: EditorPane).

## Объём

1. **Core: `Vault/VaultPath.swift`** — чистые функции над URL (без ФС):
   - `PathSegment` — сегмент breadcrumb (url, name, isDirectory);
   - `VaultPath.segments(for:isDirectory:vaultRoot:)` — цепочка сегментов от
     корня vault до файла; nil, если url вне vault;
   - `VaultPath.ancestorPaths(of:within:)` — пути папок-предков (без корня и
     без самой цели) для раскрытия дерева.
2. **`VaultManager`: reveal-механика** — `expandedFolders: Set<String>`
   (раскрытые папки дерева, ключ — путь), `revealTarget`/`revealTick`,
   `reveal(_:)` (раскрыть предков + попросить дерево проскроллить),
   `open(_:)` (= selection + reveal). `closeVault()` чистит состояние.
3. **Дерево**: `OutlineGroup` → рекурсивные `DisclosureGroup` с внешним
   биндингом раскрытия на `expandedFolders` + `ScrollViewReader`/`scrollTo`
   по reveal-запросу. Иконка узла — общий `VaultNode.systemImage`.
4. **UI: `Vault/NoteBreadcrumbView.swift`** — `NoteBreadcrumbBar` (полоска
   сегментов с chevron-разделителями, горизонтальный скролл с якорем к
   хвосту) и `FolderContentsView` (detail-панель папки: список содержимого,
   клик открывает элемент).
5. **Подключение**: detail-ветка `.notes` в `ContentView` оборачивается
   VStack'ом с breadcrumb сверху; для папок вместо `FileInfoView` —
   `FolderContentsView`. Точки внешнего выбора (`openWikilink`, backlinks,
   `.openNoteInEditor`, результат CRUD в `perform`) переведены на `open(_:)`
   — цель сразу раскрывается в дереве.

## Вне объёма

- Drag-and-drop в дереве и списке папки.
- Множественный выбор, колонки метаданных в списке папки.
- Изменение поведения поиска и quick switcher (кроме перехода на `open`).

## Критерии приёмки

- `swift build` и `swift test` зелёные; новые тесты `VaultPathTests.swift`
  покрывают: файл в корне, вложенный путь, url == корень, url вне vault,
  кириллицу/пробелы, нестандартизованные URL, ловушку префикса имён
  (`/x/Notes` vs `/x/NotesBackup`), папку как цель.
- Смоук в собранном приложении: открытая заметка показывает путь; клик по
  папке в breadcrumb открывает её содержимое и раскрывает дерево; клик по
  файлу в списке папки открывает редактор; заметка в корне — путь из двух
  сегментов; длинный кириллический путь скроллится, хвост виден.

## Результат

Сделано по плану, все пункты объёма реализованы:

- `Vault/VaultPath.swift` — `PathSegment` + `VaultPath.segments(for:isDirectory:vaultRoot:)`
  и `VaultPath.ancestorPaths(of:within:)`; 13 тестов в `VaultPathTests.swift`
  (файл/папка/корень, кириллица, нестандартизованные URL, ловушка префикса имён).
- `VaultManager` — `expandedFolders: Set<String>`, `revealTarget`/`revealTick`,
  `reveal(_:)`, `open(_:)`; `closeVault()` чистит; результат CRUD в `perform`
  теперь открывается через `open` (создание заметки раскрывает путь в дереве).
- `VaultTreeView` — `OutlineGroup` заменён на рекурсивный generic
  `VaultNodeRows<Row>` c `DisclosureGroup(isExpanded:)` поверх
  `expandedFolders` + `ScrollViewReader`/`scrollTo` по `revealTick`
  (скролл через `DispatchQueue.main.async` — строки раскрытых папок должны
  успеть вставиться). Иконки узлов — общий `VaultNode.systemImage`
  (+ статическая версия для сегментов breadcrumb).
- `Vault/NoteBreadcrumbView.swift` — `NoteBreadcrumbBar` (сегменты с
  chevron, горизонтальный скролл с якорем к хвосту, help-подсказки) и
  `FolderContentsView` (список содержимого папки, пустая — ContentUnavailableView).
- `ContentView.sectionDetail` (.notes) — VStack: breadcrumb сверху, ниже
  редактор / `FolderContentsView` (папки) / `FileInfoView` (прочие файлы).
- Точки внешнего выбора переведены на `open(_:)`: wikilinks, backlinks,
  `.openNoteInEditor`, поиск (`SearchViewModel.open`), quick switcher.

Отклонений от плана нет. Смоук пройден на установленном приложении с живым
vault (AX-скрипты): путь «Second_Brain › Изображения › <заметка>», клик по
сегменту открывает папку списком (454 строки) и укорачивает breadcrumb,
клик по файлу списка открывает его и удлиняет путь, «Показать в дереве» из
свёрнутого состояния раскрывает дерево (14 → 468 строк) и подсвечивает
заметку, корневой файл — два сегмента.

Важно для следующих задач:

- Окно приложения исключено из захвата экрана (`kCGWindowSharingState = 0`) —
  скриншоты дают обои; проверять UI только через AX (osascript).
- SwiftUI не отдаёт текст label'а `DisclosureGroup` в AX (строки-папки дерева
  выглядят пустыми для accessibility) — это поведение и старого OutlineGroup;
  имена файлов в строках видны.
- При перестроении большого дерева AX-хэндл окна на мгновение протухает
  (-1719/-1728) — в скриптах перезапрашивать window 1 после кликов.
