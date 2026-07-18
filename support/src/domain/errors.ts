// errors.ts — типизированные ошибки приложения с единым форматом для API
// (порт из manager-agent). HTTP-слой превращает их в
// `{ error: { code, message, details } }` + статус.

export type ErrorCode =
  | "validation_error"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "config_error"
  | "upstream_error"
  | "busy"
  | "internal";

export class AppError extends Error {
  constructor(
    public readonly code: ErrorCode,
    message: string,
    public readonly httpStatus: number,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = new.target.name;
  }
}

export class ValidationError extends AppError {
  constructor(message: string, details?: unknown) {
    super("validation_error", message, 400, details);
  }
}

export class UnauthorizedError extends AppError {
  constructor(message = "Требуется авторизация") {
    super("unauthorized", message, 401);
  }
}

/** Авторизован, но прав недостаточно (обычный пользователь на admin-маршруте). */
export class ForbiddenError extends AppError {
  constructor(message = "Недостаточно прав") {
    super("forbidden", message, 403);
  }
}

export class NotFoundError extends AppError {
  constructor(message = "Не найдено") {
    super("not_found", message, 404);
  }
}

export class ConflictError extends AppError {
  constructor(message = "Конфликт", details?: unknown) {
    super("conflict", message, 409, details);
  }
}

export class UpstreamError extends AppError {
  constructor(message: string, details?: unknown) {
    super("upstream_error", message, 502, details);
  }
}

/** Очередь LLM переполнена (локальная модель обслуживает запросы по одному). */
export class BusyError extends AppError {
  constructor(message = "Сервис занят, попробуйте позже", details?: unknown) {
    super("busy", message, 429, details);
  }
}
