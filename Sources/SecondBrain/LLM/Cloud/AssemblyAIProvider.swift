// AssemblyAIProvider.swift — AssemblyAI: транскрипция с диаризацией.
//
// Трёхшаговый протокол (в отличие от одного запроса у Deepgram):
//   1) upload   — POST сырых байт → {"upload_url": "..."};
//   2) transcript — POST {"audio_url", "language_code", "speaker_labels"} → id + status;
//   3) polling  — GET по id, пока status не станет terminal (completed/error).
//
// Таймкоды слов у AssemblyAI — в МИЛЛИСЕКУНДАХ (Int), в отличие от Deepgram
// (секунды, Double) — конвертация в TranscriptSegment учитывает это.
//
// Формат ошибки подтверждён живым запросом с неверным ключом:
//   {"error": "Authentication error, API token missing/invalid"}

import Foundation

/// Статус транскрипта AssemblyAI. Отдельно от провайдера — чистая логика
/// «продолжать опрашивать или нет» тестируется без сети.
enum AssemblyAITranscriptStatus: String, Decodable {
    case queued
    case processing
    case completed
    case error
}

enum AssemblyAIPolling {
    /// false — терминальный статус (completed/error), опрос можно останавливать.
    static func shouldContinuePolling(_ status: AssemblyAITranscriptStatus) -> Bool {
        status == .queued || status == .processing
    }
}

struct AssemblyAIProvider: TranscriptionProvider {
    static let id: ProviderID = "assemblyai"

    let baseURL: URL
    let defaultLanguage: String
    let pollInterval: TimeInterval
    let maxPollAttempts: Int

    init(
        baseURL: URL = URL(string: "https://api.assemblyai.com/v2")!,
        defaultLanguage: String = "ru",
        pollInterval: TimeInterval = 3,
        maxPollAttempts: Int = 200 // ~10 минут при 3-секундном интервале
    ) {
        self.baseURL = baseURL
        self.defaultLanguage = defaultLanguage
        self.pollInterval = pollInterval
        self.maxPollAttempts = maxPollAttempts
    }

    func transcribe(audioURL: URL, language: String?, hints: String?) async throws -> Transcript {
        let key = try apiKey()
        let audioData = try Data(contentsOf: audioURL)

        let uploadURL = try await upload(audioData, apiKey: key)
        let transcriptID = try await requestTranscript(
            audioURL: uploadURL,
            language: language ?? defaultLanguage,
            apiKey: key
        )
        let result = try await poll(transcriptID: transcriptID, apiKey: key)

        guard result.status == .completed else {
            throw LLMError.badStatus(code: -1, message: result.error ?? "транскрипция не завершилась успехом")
        }
        guard let text = result.text, !text.isEmpty else {
            throw LLMError.emptyResponse
        }

        let segments = Self.groupBySpeaker(result.words ?? [])
        return Transcript(fullText: text, segments: segments, language: result.language_code ?? language)
    }

    // MARK: - Шаг 1: загрузка

    private func upload(_ data: Data, apiKey: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 300

        let (responseData, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: responseData, mapError: Self.errorMessage)
        return try JSONDecoder().decode(UploadResponse.self, from: responseData).upload_url
    }

    // MARK: - Шаг 2: запрос транскрипции

    private func requestTranscript(audioURL: String, language: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcript"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TranscriptRequest(
            audio_url: audioURL,
            language_code: language,
            speaker_labels: true
        ))
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
        return try JSONDecoder().decode(TranscriptResult.self, from: data).id
    }

    // MARK: - Шаг 3: опрос

    private func poll(transcriptID: String, apiKey: String) async throws -> TranscriptResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcript/\(transcriptID)"))
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        for _ in 0..<maxPollAttempts {
            let (data, response) = try await URLSession.shared.data(for: request)
            try CloudHTTP.ensureSuccess(response, data: data, mapError: Self.errorMessage)
            let result = try JSONDecoder().decode(TranscriptResult.self, from: data)
            guard AssemblyAIPolling.shouldContinuePolling(result.status) else { return result }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw LLMError.badStatus(code: -1, message: "AssemblyAI не завершила транскрипцию за отведённое время")
    }

    /// Слова → сегменты по говорящему, как у Deepgram; start/end — из миллисекунд в секунды.
    static func groupBySpeaker(_ words: [TranscriptResult.Word]) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }
        var segments: [TranscriptSegment] = []
        var currentSpeaker = words[0].speaker
        var currentWords: [String] = []
        var start = words[0].start
        var end = words[0].end

        func flush() {
            guard !currentWords.isEmpty else { return }
            let prefix = currentSpeaker.map { "Speaker \($0): " } ?? ""
            segments.append(TranscriptSegment(
                text: prefix + currentWords.joined(separator: " "),
                start: Double(start) / 1000,
                end: Double(end) / 1000
            ))
        }

        for word in words {
            if word.speaker != currentSpeaker {
                flush()
                currentSpeaker = word.speaker
                currentWords = []
                start = word.start
            }
            currentWords.append(word.text)
            end = word.end
        }
        flush()
        return segments
    }

    private func apiKey() throws -> String {
        guard let key = KeyStore.key(for: Self.id) else { throw LLMError.missingAPIKey(Self.id) }
        return key
    }

    /// Формат ошибки AssemblyAI: {"error": "текст"} (в отличие от остальных — без вложенности).
    static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(AssemblyAIErrorResponse.self, from: data))?.error
    }
}

// MARK: - DTO

private struct UploadResponse: Decodable {
    let upload_url: String
}

private struct TranscriptRequest: Encodable {
    let audio_url: String
    let language_code: String
    let speaker_labels: Bool
}

struct TranscriptResult: Decodable {
    let id: String
    let status: AssemblyAITranscriptStatus
    let text: String?
    let language_code: String?
    let error: String?
    let words: [Word]?

    struct Word: Decodable {
        let text: String
        /// Миллисекунды от начала записи (не секунды — отличие от Deepgram).
        let start: Int
        let end: Int
        let speaker: String?
    }
}

private struct AssemblyAIErrorResponse: Decodable {
    let error: String
}
