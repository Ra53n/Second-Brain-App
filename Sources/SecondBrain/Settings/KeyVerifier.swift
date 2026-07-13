// KeyVerifier.swift — проверка API-ключа провайдера кнопкой в настройках.
//
// «Лёгкий запрос»: дешёвый GET к списочному эндпоинту провайдера (models/
// projects) — не тратит токены и однозначно отвечает, принят ли ключ.
// Секрет передаётся ТОЛЬКО в заголовке (никогда в URL — попадает в логи),
// ответ не сохраняется. Построение запроса и трактовка статуса — чистые
// функции (тестируются без сети).

import Foundation

struct KeyVerifier {
    /// Итог проверки для показа в UI.
    enum Verdict: Equatable {
        case ok
        case invalidKey
        case failed(String) // сеть/5xx — ключ, возможно, и рабочий

        var label: String {
            switch self {
            case .ok: return "ключ работает"
            case .invalidKey: return "ключ не принят"
            case .failed(let detail): return "не удалось проверить: \(detail)"
            }
        }
    }

    /// Запрос проверки для провайдера; nil — проверку не поддерживаем
    /// (локальные провайдеры без ключа сюда не попадают).
    static func request(for id: ProviderID, key: String) -> URLRequest? {
        let endpoint: (url: String, header: String, value: String)
        switch id {
        case OpenAIProvider.id:
            endpoint = ("https://api.openai.com/v1/models", "Authorization", "Bearer \(key)")
        case GeminiProvider.id:
            endpoint = ("https://generativelanguage.googleapis.com/v1beta/models", "x-goog-api-key", key)
        case DeepgramProvider.id:
            endpoint = ("https://api.deepgram.com/v1/projects", "Authorization", "Token \(key)")
        case AssemblyAIProvider.id:
            endpoint = ("https://api.assemblyai.com/v2/transcript?limit=1", "authorization", key)
        default:
            return nil
        }
        guard let url = URL(string: endpoint.url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(endpoint.value, forHTTPHeaderField: endpoint.header)
        return request
    }

    /// Трактовка HTTP-статуса: 2xx — ключ принят; 401/403 — отвергнут;
    /// остальное — не смогли проверить (не значит, что ключ плохой).
    static func verdict(statusCode: Int) -> Verdict {
        switch statusCode {
        case 200..<300: return .ok
        case 401, 403: return .invalidKey
        default: return .failed("HTTP \(statusCode)")
        }
    }

    /// Сетевая проверка ключа. Вызывается кнопкой «Проверить» в настройках.
    static func verify(id: ProviderID, key: String) async -> Verdict {
        guard let request = request(for: id, key: key) else {
            return .failed("проверка для этого провайдера не поддерживается")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("нет HTTP-ответа") }
            return verdict(statusCode: http.statusCode)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
