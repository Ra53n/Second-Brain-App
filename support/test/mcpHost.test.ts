// Тесты MCP-хоста с fake-коннектором: квалификация, маршрутизация, ошибки.

import { describe, expect, it } from "vitest";
import {
  McpHostImpl,
  qualify,
  slugify,
  type McpClientLike,
  type McpConnector,
} from "../src/mcp/mcpHost.js";
import type { McpServerConfig } from "../src/domain/types.js";

const CRM_SERVER: McpServerConfig = {
  id: "crm-1",
  name: "crm",
  command: "node",
  args: ["crm-server.js"],
  env: {},
  enabled: true,
};

function fakeClient(tools: string[], onCall?: (name: string, args: unknown) => string): McpClientLike {
  return {
    listTools: async () => ({
      tools: tools.map((name) => ({ name, description: `tool ${name}`, inputSchema: { type: "object" } })),
    }),
    callTool: async ({ name, arguments: args }) => ({
      content: [{ type: "text", text: onCall ? onCall(name, args) : `result:${name}` }],
    }),
    close: async () => {},
  };
}

describe("slugify/qualify", () => {
  it("нормализует имена", () => {
    expect(slugify("CRM Server!")).toBe("crm_server");
    expect(slugify("")).toBe("mcp");
    expect(qualify("crm", "get_ticket")).toBe("crm__get_ticket");
  });
});

describe("McpHostImpl", () => {
  it("подключает серверы и квалифицирует инструменты", async () => {
    const host = new McpHostImpl(async () => fakeClient(["find_user", "get_ticket"]));
    await host.refresh([CRM_SERVER]);
    const names = host.availableTools().map((t) => t.qualifiedName);
    expect(names).toEqual(["crm__find_user", "crm__get_ticket"]);
    expect(host.statuses()[0]).toMatchObject({ connected: true, toolCount: 2 });
  });

  it("маршрутизирует вызов и передаёт аргументы", async () => {
    let got: unknown;
    const host = new McpHostImpl(async () =>
      fakeClient(["get_ticket"], (name, args) => {
        got = args;
        return "данные тикета";
      }),
    );
    await host.refresh([CRM_SERVER]);
    const out = await host.call("crm__get_ticket", '{"id":"t-101"}');
    expect(out).toBe("данные тикета");
    expect(got).toEqual({ id: "t-101" });
  });

  it("неизвестный инструмент → ERROR-строка, не исключение", async () => {
    const host = new McpHostImpl(async () => fakeClient(["a"]));
    await host.refresh([CRM_SERVER]);
    expect(await host.call("nope__tool", "{}")).toContain("ERROR");
  });

  it("сбой подключения → статус с ошибкой, refresh не падает", async () => {
    const failing: McpConnector = async () => {
      throw new Error("spawn failed");
    };
    const host = new McpHostImpl(failing);
    await host.refresh([CRM_SERVER]);
    expect(host.availableTools()).toEqual([]);
    expect(host.statuses()[0]).toMatchObject({ connected: false, error: "spawn failed" });
  });

  it("выключенный сервер отключается при refresh", async () => {
    const host = new McpHostImpl(async () => fakeClient(["a"]));
    await host.refresh([CRM_SERVER]);
    expect(host.availableTools()).toHaveLength(1);
    await host.refresh([{ ...CRM_SERVER, enabled: false }]);
    expect(host.availableTools()).toHaveLength(0);
  });

  it("isError от инструмента → ERROR-строка", async () => {
    const client: McpClientLike = {
      listTools: async () => ({ tools: [{ name: "t", description: "", inputSchema: {} }] }),
      callTool: async () => ({ content: [{ type: "text", text: "сломалось" }], isError: true }),
      close: async () => {},
    };
    const host = new McpHostImpl(async () => client);
    await host.refresh([CRM_SERVER]);
    expect(await host.call("crm__t", "{}")).toBe("ERROR: сломалось");
  });
});
