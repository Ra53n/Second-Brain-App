// crm-server.ts — stdio MCP-сервер CRM поверх JSON-файлов (users/tickets).
//
// Отдельный процесс: его спавнит mcpHost по конфигу из mcp_servers (сервис
// регистрирует его автоматически при первом старте). Каталог с данными приходит
// в env CRM_DATA_DIR. Инструменты — референс интеграции с CRM: заменив этот
// сервер на MCP реальной CRM, ассистент получает живые данные без правок кода.
//
// Хендлеры вынесены в чистые функции (crmToolHandlers) — юнит-тесты гоняют их
// без спавна процесса.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { CrmStore } from "../crm/crmStore.js";
import type { TicketStatus } from "../domain/types.js";
import { TICKET_STATUSES } from "../domain/types.js";

export interface CrmToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export const CRM_TOOLS: CrmToolDef[] = [
  {
    name: "find_user",
    description:
      "Найти пользователя продукта по имени, email или id (подстрока). Возвращает список совпадений.",
    inputSchema: {
      type: "object",
      required: ["query"],
      properties: { query: { type: "string", description: "Имя, email или id" } },
    },
  },
  {
    name: "get_user",
    description: "Профиль пользователя по id (версия приложения, macOS, заметки).",
    inputSchema: {
      type: "object",
      required: ["id"],
      properties: { id: { type: "string" } },
    },
  },
  {
    name: "list_tickets",
    description:
      "Список тикетов поддержки. Фильтры: user_id (тикеты клиента) и/или status (open|pending|closed).",
    inputSchema: {
      type: "object",
      properties: {
        user_id: { type: "string" },
        status: { type: "string", enum: [...TICKET_STATUSES] },
      },
    },
  },
  {
    name: "get_ticket",
    description: "Тикет целиком по id, включая всю переписку.",
    inputSchema: {
      type: "object",
      required: ["id"],
      properties: { id: { type: "string" } },
    },
  },
  {
    name: "add_ticket_comment",
    description: "Добавить комментарий от поддержки в тикет (id тикета + текст).",
    inputSchema: {
      type: "object",
      required: ["id", "text"],
      properties: { id: { type: "string" }, text: { type: "string" } },
    },
  },
];

type ToolArgs = Record<string, unknown>;

/**
 * Чистые обработчики инструментов: имя → (store, args) → текст результата.
 * Ошибки данных возвращаются текстом (isError решает вызывающий), не бросаются.
 */
export const crmToolHandlers: Record<
  string,
  (store: CrmStore, args: ToolArgs, now: () => Date) => string
> = {
  find_user: (store, args) => {
    const query = String(args.query ?? "");
    const found = store.searchUsers(query);
    if (found.length === 0) return `Пользователи по запросу «${query}» не найдены.`;
    return JSON.stringify(found, null, 2);
  },
  get_user: (store, args) => {
    const id = String(args.id ?? "");
    const user = store.getUser(id);
    return user ? JSON.stringify(user, null, 2) : `Пользователь «${id}» не найден.`;
  },
  list_tickets: (store, args) => {
    const userId = args.user_id ? String(args.user_id) : undefined;
    const status = args.status ? (String(args.status) as TicketStatus) : undefined;
    const tickets = store
      .listTickets({ userId, status })
      // Список — без полной переписки (детали добираются get_ticket).
      .map(({ messages, ...rest }) => ({ ...rest, messageCount: (messages ?? []).length }));
    return tickets.length > 0 ? JSON.stringify(tickets, null, 2) : "Тикетов не найдено.";
  },
  get_ticket: (store, args) => {
    const id = String(args.id ?? "");
    const ticket = store.getTicket(id);
    return ticket ? JSON.stringify(ticket, null, 2) : `Тикет «${id}» не найден.`;
  },
  add_ticket_comment: (store, args, now) => {
    const id = String(args.id ?? "");
    const text = String(args.text ?? "").trim();
    if (!text) return "Пустой текст комментария.";
    const updated = store.addTicketComment(id, "support", text, now().toISOString());
    return updated ? `Комментарий добавлен в тикет ${id}.` : `Тикет «${id}» не найден.`;
  },
};

async function main(): Promise<void> {
  const dir = (process.env.CRM_DATA_DIR ?? "/opt/support-assistant/data/crm").trim();
  const store = new CrmStore(dir);

  const server = new Server(
    { name: "crm", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: CRM_TOOLS }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const handler = crmToolHandlers[req.params.name];
    if (!handler) {
      return { content: [{ type: "text", text: `Неизвестный инструмент: ${req.params.name}` }], isError: true };
    }
    try {
      const text = handler(store, (req.params.arguments ?? {}) as ToolArgs, () => new Date());
      return { content: [{ type: "text", text }] };
    } catch (e) {
      return { content: [{ type: "text", text: (e as Error).message }], isError: true };
    }
  });

  await server.connect(new StdioServerTransport());
}

// Не стартуем сервер при импорте из тестов.
if (process.argv[1] && process.argv[1].endsWith("crm-server.js")) {
  main().catch((e) => {
    console.error(`[crm-server] фатальная ошибка: ${(e as Error).message}`);
    process.exit(1);
  });
}
