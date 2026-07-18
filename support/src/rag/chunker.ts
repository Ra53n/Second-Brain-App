// chunker.ts — структурный чанкер markdown (порт RagChunker.swift Second Brain).
//
// Чанк несёт заголовочный путь («H1 > H2») — так ретрив подписывает источники.
// Заголовки внутри код-блоков (``` … ```) заголовками не считаются. Слишком
// длинные разделы дорезаются по границам строк с сохранением пути.

export interface KbChunk {
  filePath: string; // относительный путь файла в KB
  headingPath: string; // «H1 > H2»; преамбула до заголовков — пустая строка
  text: string;
}

/** Потолок длины чанка в символах (~400–500 токенов для русского). */
export const DEFAULT_MAX_CHARS = 1400;

/** ATX-заголовок markdown: уровень и текст («## Планы» → {level:2, title:"Планы"}). */
export function headingTitle(line: string): { level: number; title: string } | null {
  const trimmed = line.replace(/^ +/, "");
  if (!trimmed.startsWith("#")) return null;
  let hashes = 0;
  while (hashes < trimmed.length && trimmed[hashes] === "#") hashes++;
  if (hashes < 1 || hashes > 6) return null;
  if (trimmed[hashes] !== " ") return null; // CommonMark: нужен пробел после решёток
  const title = trimmed.slice(hashes + 1).trim();
  return { level: hashes, title };
}

/** Режет текст файла на чанки по структуре заголовков. Пустой текст → []. */
export function chunkMarkdown(
  text: string,
  filePath: string,
  maxChars = DEFAULT_MAX_CHARS,
): KbChunk[] {
  const lines = text.split("\n");

  interface Section {
    headingPath: string;
    lines: string[];
  }

  const sections: Section[] = [];
  const headingStack: Array<{ level: number; title: string }> = [];
  let current: Section = { headingPath: "", lines: [] };
  let inCodeFence = false;

  const flushCurrent = () => {
    if (current.lines.some((l) => l.trim() !== "")) sections.push(current);
  };

  for (const line of lines) {
    if (line.trim().startsWith("```")) inCodeFence = !inCodeFence;
    const heading = inCodeFence ? null : headingTitle(line);
    if (heading) {
      flushCurrent();
      // Обновляем стек: срезаем уровни ≥ текущего, кладём новый.
      while (headingStack.length > 0 && headingStack[headingStack.length - 1]!.level >= heading.level) {
        headingStack.pop();
      }
      headingStack.push(heading);
      current = {
        headingPath: headingStack.map((h) => h.title).join(" > "),
        lines: [line], // заголовок включён в тело — он несёт смысл для эмбеддинга
      };
    } else {
      current.lines.push(line);
    }
  }
  flushCurrent();

  // Разделы → чанки (длинные дорезаются по границам строк).
  const chunks: KbChunk[] = [];
  for (const section of sections) {
    const body = section.lines.join("\n");
    if (body.trim() === "") continue;
    if (body.length <= maxChars) {
      chunks.push({ filePath, headingPath: section.headingPath, text: body });
    } else {
      chunks.push(...splitLongSection(section.lines, section.headingPath, filePath, maxChars));
    }
  }
  return chunks;
}

/**
 * Вторичная нарезка длинного раздела: копим строки до maxChars, режем на границе
 * строки; строка-монстр длиннее лимита становится собственным чанком.
 */
function splitLongSection(
  lines: string[],
  headingPath: string,
  filePath: string,
  maxChars: number,
): KbChunk[] {
  const chunks: KbChunk[] = [];
  let buffer: string[] = [];
  let bufferChars = 0;

  const flush = () => {
    const text = buffer.join("\n");
    if (text.trim() !== "") chunks.push({ filePath, headingPath, text });
    buffer = [];
    bufferChars = 0;
  };

  for (const line of lines) {
    if (bufferChars + line.length > maxChars && buffer.length > 0) flush();
    buffer.push(line);
    bufferChars += line.length + 1;
  }
  flush();
  return chunks;
}
