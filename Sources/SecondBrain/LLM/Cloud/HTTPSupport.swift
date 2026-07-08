// HTTPSupport.swift — общие утилиты HTTP-клиентов облачных провайдеров.
//
// Здесь живут:
//  - CloudHTTP        — проверка статус-кода с провайдер-специфичным маппингом
//                        ошибки, дочитывание AsyncBytes для тела ошибки в стриме;
//  - SSEStream        — парсер Server-Sent Events («data: {json}\n\n», [DONE]),
//                        работает над ЛЮБЫМ AsyncSequence<String> — тестируется
//                        синтетической последовательностью строк, без сети;
//  - MultipartFormData — сборка multipart/form-data руками, без библиотек
//                        (загрузка аудио — Whisper, AssemblyAI).
//
// Эталон обработки не-2xx с телом ошибки — DeepSeekClient.swift из Manager
// Assistant; здесь то же самое, но параметризовано под 4 разных провайдера
// сразу (у каждого свой формат ошибки — маппер передаётся вызывающим).

import Foundation

enum CloudHTTP {
    /// Бросает LLMError.badStatus, если статус не 2xx. `mapError` декодирует
    /// провайдер-специфичный JSON ошибки в читаемое сообщение; если это не
    /// удаётся — используется сырой текст тела.
    static func ensureSuccess(_ response: URLResponse, data: Data, mapError: (Data) -> String?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badStatus(code: -1, message: "нет HTTP-ответа")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = mapError(data) ?? String(data: data, encoding: .utf8) ?? "неизвестная ошибка"
            throw LLMError.badStatus(code: http.statusCode, message: message)
        }
    }

    /// Дочитывает поток байт целиком — нужно, чтобы получить тело ошибки, когда
    /// статус стриминг-ответа оказался не 2xx (AsyncBytes — одноразовый).
    static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
}

/// Парсер Server-Sent Events. OpenAI и Gemini (при `alt=sse`) отдают поток в
/// одном формате: строки `data: <json>`, пустые строки — разделители событий,
/// OpenAI дополнительно шлёт терминатор `data: [DONE]`. Работает над абстрактным
/// AsyncSequence<String> (не завязан на URLSession) — тесты кормят массив строк.
enum SSEStream {
    static func payloads<Lines: AsyncSequence>(
        from lines: Lines
    ) -> AsyncThrowingStream<String, Error> where Lines.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Сборка multipart/form-data body без сторонних библиотек: текстовые поля +
/// один файл (достаточно для audio/transcriptions и AssemblyAI upload).
struct MultipartFormData {
    let boundary = "Boundary-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8Data)
        body.append(value.utf8Data)
        body.append("\r\n".utf8Data)
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(data)
        body.append("\r\n".utf8Data)
    }

    /// Финализирует body закрывающим boundary — вызывать один раз, последним.
    mutating func finalize() -> Data {
        body.append("--\(boundary)--\r\n".utf8Data)
        return body
    }
}

extension String {
    /// UTF-8 представление строки — используется при ручной сборке multipart-body
    /// во всех облачных провайдерах (не private: нужна за пределами этого файла).
    var utf8Data: Data { Data(utf8) }
}
