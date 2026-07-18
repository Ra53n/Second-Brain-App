// schemas.ts — JSON-схемы валидации тел запросов (Fastify+ajv).
// additionalProperties:true — снисходительно к будущим полям.

export const loginBody = {
  type: "object",
  required: ["username", "password"],
  properties: {
    username: { type: "string" },
    password: { type: "string" },
  },
} as const;

export const createUserBody = {
  type: "object",
  required: ["username", "password"],
  properties: {
    username: { type: "string" },
    password: { type: "string" },
    email: { type: "string" },
    isAdmin: { type: "boolean" },
  },
} as const;

export const createChatBody = {
  type: "object",
  additionalProperties: true,
  properties: {
    title: { type: "string" },
  },
} as const;

export const sendChatMessageBody = {
  type: "object",
  required: ["content"],
  properties: {
    content: { type: "string", minLength: 1, maxLength: 100000 },
    stream: { type: "boolean" },
  },
} as const;

// Гостевой чат (без аккаунта): всю историю присылает клиент, сервер НЕ хранит.
export const guestChatBody = {
  type: "object",
  additionalProperties: true,
  required: ["messages"],
  properties: {
    stream: { type: "boolean" },
    messages: {
      type: "array",
      maxItems: 40,
      items: {
        type: "object",
        required: ["role", "content"],
        properties: {
          role: { type: "string", enum: ["user", "assistant"] },
          content: { type: "string", minLength: 1, maxLength: 100000 },
        },
      },
    },
  },
} as const;

export const settingsBody = {
  type: "object",
  additionalProperties: true,
  properties: {
    provider: { type: "string" },
    llmApiKey: { type: "string" },
    remoteModel: { type: "string" },
    localModel: { type: "string" },
    embedModel: { type: "string" },
    systemPrompt: { type: "string" },
    maxIterations: { type: "number" },
    rag: {
      type: "object",
      additionalProperties: true,
      properties: {
        topK: { type: "number" },
        candidateK: { type: "number" },
        minScore: { type: "number" },
        budgetTokens: { type: "number" },
      },
    },
  },
} as const;

export const kbFileQuery = {
  type: "object",
  required: ["name"],
  properties: { name: { type: "string" } },
} as const;

export const kbFileBody = {
  type: "object",
  required: ["name", "content"],
  properties: {
    name: { type: "string" },
    content: { type: "string", maxLength: 1000000 },
  },
} as const;

export const kbSearchBody = {
  type: "object",
  required: ["query"],
  properties: { query: { type: "string", minLength: 1 } },
} as const;

const mcpServerSchema = {
  type: "object",
  additionalProperties: true,
  required: ["id", "name", "command"],
  properties: {
    id: { type: "string" },
    name: { type: "string" },
    command: { type: "string" },
    args: { type: "array", items: { type: "string" } },
    env: { type: "object", additionalProperties: { type: "string" } },
    enabled: { type: "boolean" },
  },
} as const;

export const mcpServersBody = {
  type: "object",
  required: ["servers"],
  properties: {
    servers: { type: "array", items: mcpServerSchema },
  },
} as const;

// Фидбек «решено/не решено»: у вошедших — chatId (email из аккаунта), у гостя —
// email из формы + история диалога из браузера.
export const feedbackBody = {
  type: "object",
  additionalProperties: true,
  required: ["resolved"],
  properties: {
    resolved: { type: "boolean" },
    chatId: { type: "string" },
    email: { type: "string", maxLength: 200 },
    name: { type: "string", maxLength: 200 },
    comment: { type: "string", maxLength: 4000 },
    messages: {
      type: "array",
      maxItems: 40,
      items: {
        type: "object",
        required: ["role", "content"],
        properties: {
          role: { type: "string", enum: ["user", "assistant"] },
          content: { type: "string", maxLength: 100000 },
        },
      },
    },
  },
} as const;

export const ticketStatusBody = {
  type: "object",
  required: ["status"],
  properties: { status: { type: "string", enum: ["open", "pending", "closed"] } },
} as const;

export const ticketCommentBody = {
  type: "object",
  required: ["text"],
  properties: { text: { type: "string", minLength: 1, maxLength: 8000 } },
} as const;

// CRM-редакторы принимают массив целиком (валидация схемы — в CrmStore).
export const crmArrayBody = {
  type: "object",
  required: ["items"],
  properties: { items: { type: "array" } },
} as const;
