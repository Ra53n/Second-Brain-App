// reindex.ts — CLI переиндексации базы знаний (деплой/отладка/cron).
//
// Запуск на VPS:
//   SUPPORT_DB_PATH=… SUPPORT_KB_DIR=… OLLAMA_URL=… \
//     node /opt/support-assistant/dist/scripts/reindex.js [--embed-model=bge-m3]

import { openDb } from "../store/db.js";
import { KbRepo } from "../store/kbRepo.js";
import { KbIndexer } from "../rag/indexer.js";
import { OllamaClient } from "../llm/ollamaClient.js";
import { OllamaEmbedder } from "../rag/embedder.js";
import { SettingsRepo } from "../store/settingsRepo.js";

async function main(): Promise<void> {
  const dbPath = (process.env.SUPPORT_DB_PATH ?? "/opt/support-assistant/data/support.db").trim();
  const kbDir = (process.env.SUPPORT_KB_DIR ?? "/opt/support-assistant/data/kb").trim();
  const ollamaUrl = (process.env.OLLAMA_URL ?? "http://127.0.0.1:11434").trim();

  const db = openDb(dbPath);
  try {
    const modelArg = process.argv.find((a) => a.startsWith("--embed-model="));
    const model = modelArg
      ? modelArg.slice("--embed-model=".length)
      : new SettingsRepo(db).get().embedModel;

    const repo = new KbRepo(db);
    const indexer = new KbIndexer(repo, kbDir);
    const embedder = new OllamaEmbedder(new OllamaClient({ baseUrl: ollamaUrl }), model);
    console.log(`Индексирую ${kbDir} моделью ${model}…`);
    const { chunkCount } = await indexer.reindex(embedder);
    console.log(`✓ Готово: ${chunkCount} чанков.`);
  } catch (e) {
    console.error(`Ошибка: ${(e as Error).message}`);
    process.exit(1);
  } finally {
    db.close();
  }
}

main();
