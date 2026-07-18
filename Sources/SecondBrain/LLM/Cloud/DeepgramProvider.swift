// DeepgramProvider.swift — Deepgram: транскрипция prerecorded-аудио с диаризацией.
//
// Только TranscriptionProvider — у Deepgram нет чата/эмбеддингов в нашем смысле.
// Запрос — сырые байты аудио в теле (Content-Type = mime-тип файла), не multipart;
// параметры (язык, диаризация, форматирование) — в query string.
//
// Deepgram отдаёт слова с таймкодами и speaker-метками (диаризация). Здесь они
// группируются в сегменты по говорящему (подряд идущие слова одного speaker'а —
// один сегмент с префиксом «Speaker N:») — полноценный UI диаризации в задаче 19,
// сейчас важно не потерять информацию.
//
// Формат ошибки подтверждён живым запросом с неверным ключом:
//   {"err_code": "INVALID_AUTH", "err_msg": "Invalid credentials.", "request_id": "..."}

import Foundation

struct DeepgramProvider: TranscriptionProvider {
    static let id: ProviderID = "deepgram"

    /// Модель транскрипции по умолчанию — она же в дескрипторе регистрации.
    static let defaultModel = "nova-2"

    let baseURL: URL
    /// Модель «зашита» в экземпляр (протокол TranscriptionProvider не принимает
    /// модель параметром). Без явного model= в query Deepgram использовал БАЗОВУЮ
    /// модель — заметно хуже nova-2 на русской речи.
    let model: String
    /// Язык по умолчанию, если вызывающий не указал (задача 11 сравнивает
    /// провайдеров на русской речи — разумный дефолт для этого приложения).
    let defaultLanguage: String

    init(baseURL: URL = URL(string: "https://api.deepgram.com/v1")!,
         model: String = DeepgramProvider.defaultModel,
         defaultLanguage: String = "ru") {
        self.baseURL = baseURL
        self.model = model
        self.defaultLanguage = defaultLanguage
    }

    func transcribe(audioURL: URL, language: String?, hints: String?) async throws -> Transcript {
        guard let key = KeyStore.key(for: Self.id) else { throw LLMError.missingAPIKey(Self.id) }
        let audioData = try Data(contentsOf: audioURL)
        let resolvedLanguage = language ?? defaultLanguage
        let url = baseURL.appendingPathComponent("listen")
            .appending(queryItems: Self.queryItems(model: model, language: resolvedLanguage, hints: hints))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.mimeType(for: audioURL), forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        guard let alternative = decoded.results?.channels.first?.alternatives.first else {
            throw LLMError.emptyResponse
        }
        return Transcript(
            fullText: alternative.transcript,
            segments: Self.groupBySpeaker(alternative.words ?? []),
            language: resolvedLanguage
        )
    }

    /// Параметры запроса /listen — чистая функция для тестируемости.
    static func queryItems(model: String, language: String, hints: String?) -> [URLQueryItem] {
        var queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true")
        ]
        if let hints, !hints.isEmpty {
            // Deepgram использует keyterms/keywords для подсказки словаря;
            // склеиваем через запятую в один параметр (простое, документированное поведение).
            queryItems.append(URLQueryItem(name: "keywords", value: hints))
        }
        return queryItems
    }

    /// Склеивает подряд идущие слова одного speaker'а в один сегмент с меткой.
    /// Слова без speaker (моно-канал без диаризации) — один сегмент без метки.
    static func groupBySpeaker(_ words: [DeepgramResponse.Word]) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }
        var segments: [TranscriptSegment] = []
        var currentSpeaker: Int? = words[0].speaker
        var currentWords: [String] = []
        var start = words[0].start
        var end = words[0].end

        func flush() {
            guard !currentWords.isEmpty else { return }
            let prefix = currentSpeaker.map { "Speaker \($0): " } ?? ""
            segments.append(TranscriptSegment(text: prefix + currentWords.joined(separator: " "), start: start, end: end))
        }

        for word in words {
            if word.speaker != currentSpeaker {
                flush()
                currentSpeaker = word.speaker
                currentWords = []
                start = word.start
            }
            currentWords.append(word.word)
            end = word.end
        }
        flush()
        return segments
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        default: return "audio/mpeg"
        }
    }

    /// Формат ошибки Deepgram: {"err_code": ..., "err_msg": ..., "request_id": ...}.
    static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(DeepgramErrorResponse.self, from: data))?.err_msg
    }
}

// MARK: - DTO ответа

struct DeepgramResponse: Decodable {
    let results: Results?
    struct Results: Decodable {
        let channels: [Channel]
    }
    struct Channel: Decodable {
        let alternatives: [Alternative]
    }
    struct Alternative: Decodable {
        let transcript: String
        let words: [Word]?
    }
    struct Word: Decodable {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let speaker: Int?
    }
}

private struct DeepgramErrorResponse: Decodable {
    let err_code: String
    let err_msg: String
}
