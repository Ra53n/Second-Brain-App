// FetchUrlTool.swift — встроенный инструмент загрузки веб-страницы (задача 102).
//
// Транспорт инжектируется (как GitHubClient.perform) — тесты идут без сети.
// URL от модели — недоверенный ввод: только http/https, GET, таймаут, кап тела,
// бинарник отклоняется тем же способом, что и read_file (NUL-байт).

import Foundation

/// Загрузка страницы по URL. Классифицируется как `.write` (ToolRiskClassifier) —
/// сетевой egress считается побочным эффектом, а не безопасным чтением.
struct FetchUrlTool: BuiltinTool {
    /// Кап тела ответа — как у read_file, модели больше не нужно.
    static let maxBytes = 64 * 1024
    /// Таймаут запроса: страница должна ответить быстро либо не отвечать вовсе.
    static let timeout: TimeInterval = 20

    let name = "fetch_url"
    let description = "Загрузить содержимое веб-страницы по URL (HTTP GET) и вернуть текст."
    let parameters = ToolSchemas.object([
        "url": ToolSchemas.string("Полный URL страницы (http/https)")
    ], required: ["url"])

    /// Дефолт — URLSession.shared; в тестах подменяется фикстурой без сети.
    var perform: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let raw = ctx.input("url"), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            return .error("fetch_url поддерживает только http/https URL")
        }

        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"

        let data: Data
        do {
            (data, _) = try await perform(request)
        } catch {
            return .error("не удалось загрузить \(raw): \(error.localizedDescription)")
        }

        let truncated = data.count > Self.maxBytes
        let payload = truncated ? data.prefix(Self.maxBytes) : data
        // NUL-байт — надёжный признак бинарника (тот же приём, что read_file).
        guard !payload.contains(0) else {
            return .error("бинарный ответ, не текст")
        }
        var text = String(data: payload, encoding: .utf8) ?? String(decoding: payload, as: UTF8.self)
        if truncated {
            text += "\n…(страница обрезана до \(Self.maxBytes) байт)"
        }
        return .ok(text)
    }
}
