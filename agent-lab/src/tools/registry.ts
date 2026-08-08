// registry.ts — контракт инструмента и сборка набора для модели.
//
// Порт идеи BuiltinTool/ToolRegistry из Swift-приложения: инструмент — это один
// файл с именем, описанием, JSON-схемой и `execute`. Главная конвенция:
// **execute никогда не бросает** — любая ошибка возвращается строкой
// `ERROR: …`, уходит модели как обычный результат, и модель сама корректируется
// (см. runToolLoop: успех вызова определяется по отсутствию префикса ERROR).

import type { ToolDef } from "../llm/openaiClient.js";

export interface LabTool {
  name: string;
  description: string;
  /** JSON Schema объекта аргументов. */
  parameters: unknown;
  execute(args: Record<string, unknown>): Promise<string>;
}

export function toolDefs(tools: LabTool[]): ToolDef[] {
  return tools.map((t) => ({
    type: "function",
    function: { name: t.name, description: t.description, parameters: t.parameters },
  }));
}

/** Строковый аргумент из разобранного JSON: всё, что не строка, — пусто. */
export function stringArg(args: Record<string, unknown>, key: string): string {
  const value = args[key];
  return typeof value === "string" ? value.trim() : "";
}

/**
 * Маршрутизатор вызовов для tool-loop. Разбирает JSON аргументов, находит
 * инструмент, ловит любые исключения и превращает их в `ERROR: …`.
 */
export function makeExecutor(tools: LabTool[]): (name: string, argsJSON: string) => Promise<string> {
  const byName = new Map(tools.map((t) => [t.name, t]));
  return async (name, argsJSON) => {
    const tool = byName.get(name);
    if (!tool) return `ERROR: неизвестный инструмент «${name}»`;
    let args: Record<string, unknown>;
    try {
      const raw = argsJSON.trim() === "" ? "{}" : argsJSON;
      const parsed = JSON.parse(raw);
      args = parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
    } catch {
      return `ERROR: аргументы «${name}» не являются корректным JSON`;
    }
    try {
      return await tool.execute(args);
    } catch (e) {
      return `ERROR: сбой инструмента «${name}»: ${(e as Error).message}`;
    }
  };
}
