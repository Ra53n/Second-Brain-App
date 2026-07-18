// MeetingModels.swift — доменная модель пайплайна встречи (задача 11).
//
// Здесь живут:
//  - MeetingState: этапы пайплайна; допустимость переходов задаёт ТАБЛИЦА
//    MeetingFSM.transitions (порт паттерна TaskFSM из Manager Assistant);
//  - MeetingRunStatus: статус прогона ПОВЕРХ этапа (running/paused/…) — этап
//    говорит «что делаем», статус — «жив ли прогон» (как TaskRunStatus в MA);
//  - MeetingContext: персистентная сущность встречи (Codable, снисходительный
//    init(from:) — каждый ключ через decodeIfPresent, паттерн TaskContext);
//  - MeetingError: ошибки пайплайна с сообщениями для UI.
//
// Crash-safety: контекст сохраняется после КАЖДОГО перехода (persistNow в
// MeetingStore); на старте приложения зависшие running → paused; run()
// пайплайна идемпотентен — продолжает с текущего state.

import Foundation

/// Этап пайплайна встречи. Переходы — только по таблице MeetingFSM.
enum MeetingState: String, Codable, CaseIterable, Identifiable {
    case recorded       // запись есть, пайплайн не начат
    case transcribing   // идёт транскрипция
    case transcribed    // транскрипт готов
    case summarizing    // LLM делает summary + предлагает название/папку
    case awaitingTitle  // ждём подтверждения названия/папки пользователем
    case filing         // раскладываем: пишем заметку в vault
    case done           // терминал: заметка создана
    case failed         // шаг упал (failedStage хранит, какой) — можно ретраить

    var id: String { rawValue }

    /// Снисходительное декодирование: неизвестный этап → .recorded
    /// (пайплайн просто переиграет с начала — шаги идемпотентны).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingState(rawValue: raw) ?? .recorded
    }

    var label: String {
        switch self {
        case .recorded: return "Записано"
        case .transcribing: return "Транскрипция…"
        case .transcribed: return "Транскрипт готов"
        case .summarizing: return "Саммари…"
        case .awaitingTitle: return "Ждёт название"
        case .filing: return "Раскладка…"
        case .done: return "Готово"
        case .failed: return "Ошибка"
        }
    }
}

/// Статус прогона пайплайна (поверх этапа).
enum MeetingRunStatus: String, Codable {
    case running      // этап в полёте (есть живой Task)
    case paused       // остановлен (рестарт приложения / вручную) — можно продолжить
    case awaitingUser // ждём ответа пользователя (диалог названия/папки)
    case failed       // шаг упал после ретраев
    case finished     // дошли до done

    /// Снисходительное декодирование: неизвестное → .paused (всегда возобновляемо).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingRunStatus(rawValue: raw) ?? .paused
    }
}

/// Детерминированный конечный автомат: единственный источник истины о том,
/// из какого этапа в какие МОЖНО перейти. Любой переход вне таблицы запрещён.
enum MeetingFSM {
    static let transitions: [MeetingState: [MeetingState]] = [
        .recorded:      [.transcribing],
        .transcribing:  [.transcribed, .failed],
        .transcribed:   [.summarizing],
        .summarizing:   [.awaitingTitle, .filing, .failed], // с заданным заранее названием — сразу filing
        .awaitingTitle: [.filing],
        .filing:        [.done, .failed],
        .failed:        [.transcribing, .summarizing, .filing], // ретрай упавшего шага
        .done:          []                                       // терминал
    ]

    /// Разрешён ли переход from → to по таблице.
    static func allows(_ from: MeetingState, to: MeetingState) -> Bool {
        transitions[from, default: []].contains(to)
    }
}

/// Транскрипт одной дорожки записи (в режиме «оба» их две: микрофон и система).
struct TrackTranscript: Codable, Equatable {
    var fileName: String      // имя аудиофайла в _recordings/
    var transcript: Transcript

    /// Подпись дорожки для заметки/промпта.
    var label: String {
        fileName.contains(RecordingNamer.systemTrackSuffix) ? "Собеседники (система)" : "Микрофон"
    }

    /// Текст дорожки для промпта: из сегментов, если они есть, — у Deepgram/
    /// AssemblyAI метки «Speaker N:» живут ТОЛЬКО в сегментах, и сборка из
    /// fullText теряла диаризацию для саммари. Без сегментов — fullText.
    var promptText: String {
        guard !transcript.segments.isEmpty else { return transcript.fullText }
        return transcript.segments.map(\.text).joined(separator: "\n")
    }
}

/// Персистентная сущность встречи — контекст автомата.
struct MeetingContext: Codable, Identifiable, Equatable {
    var id = UUID()
    // --- связь с записью (задача 06) ---
    var recordingBase: String            // базовое имя записи — ключ связи со списком
    var audioFiles: [String] = []        // имена дорожек в _recordings/
    var recordedAt: Date = .distantPast
    var duration: TimeInterval = 0
    // --- автомат ---
    var state: MeetingState = .recorded
    var status: MeetingRunStatus = .paused
    // --- артефакты этапов ---
    var presetTitle: String? = nil       // название, заданное ДО записи (минует awaitingTitle)
    var transcripts: [TrackTranscript] = []
    var transcriptionProviderID: String? = nil
    var summary: String = ""
    var suggestedTitle: String = ""      // предложение LLM
    var suggestedFolder: String = ""     // предложение LLM (уже провалидированное)
    var folderWasInvalid: Bool = false   // LLM предложил несуществующую папку — применён фолбэк
    var confirmedTitle: String? = nil    // выбор пользователя из диалога
    var confirmedFolder: String? = nil
    var notePath: String? = nil          // относительный путь готовой заметки в vault
    // --- ошибки/ретраи ---
    var stepRetries: Int = 0             // повторы ТЕКУЩЕГО шага (сбрасывается при успехе)
    var failedStage: MeetingState? = nil // какой этап упал (для ретрая из failed)
    var errorText: String? = nil
    var startedAt: Date = Date()

    /// Лимит автоматических повторов одного шага (как maxExecutionRetries в MA).
    static let maxStepRetries = 2

    /// Название для заметки: выбор пользователя > заданное заранее > предложение LLM.
    var effectiveTitle: String {
        confirmedTitle ?? presetTitle ?? suggestedTitle
    }

    /// Папка для заметки: выбор пользователя > провалидированное предложение LLM.
    var effectiveFolder: String {
        confirmedFolder ?? suggestedFolder
    }

    /// Полный текст всех дорожек для summary-промпта (с метками спикеров,
    /// когда провайдер их дал, — см. TrackTranscript.promptText).
    var combinedTranscriptText: String {
        guard transcripts.count > 1 else { return transcripts.first?.promptText ?? "" }
        return transcripts
            .map { "[\($0.label)]\n\($0.promptText)" }
            .joined(separator: "\n\n")
    }

    /// Детерминированный переход по таблице. Нелегальный скачок — ошибка
    /// программиста (precondition, как в MA): в рантайме такого быть не может.
    func transitioned(to target: MeetingState) -> MeetingContext {
        precondition(MeetingFSM.allows(state, to: target),
                     "Недопустимый переход \(state.rawValue) → \(target.rawValue)")
        var c = self
        c.state = target
        return c
    }

    enum CodingKeys: String, CodingKey {
        case id, recordingBase, audioFiles, recordedAt, duration
        case state, status
        case presetTitle, transcripts, transcriptionProviderID
        case summary, suggestedTitle, suggestedFolder, folderWasInvalid
        case confirmedTitle, confirmedFolder, notePath
        case stepRetries, failedStage, errorText, startedAt
    }

    init(recordingBase: String,
         audioFiles: [String],
         recordedAt: Date,
         duration: TimeInterval,
         presetTitle: String? = nil) {
        self.recordingBase = recordingBase
        self.audioFiles = audioFiles
        self.recordedAt = recordedAt
        self.duration = duration
        self.presetTitle = presetTitle
    }

    /// Миграционно-устойчивое декодирование (паттерн TaskContext из MA):
    /// каждый ключ через decodeIfPresent с дефолтом — старый JSON грузится всегда.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        recordingBase = try c.decodeIfPresent(String.self, forKey: .recordingBase) ?? ""
        audioFiles = try c.decodeIfPresent([String].self, forKey: .audioFiles) ?? []
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt) ?? .distantPast
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        state = try c.decodeIfPresent(MeetingState.self, forKey: .state) ?? .recorded
        status = try c.decodeIfPresent(MeetingRunStatus.self, forKey: .status) ?? .paused
        presetTitle = try c.decodeIfPresent(String.self, forKey: .presetTitle)
        transcripts = try c.decodeIfPresent([TrackTranscript].self, forKey: .transcripts) ?? []
        transcriptionProviderID = try c.decodeIfPresent(String.self, forKey: .transcriptionProviderID)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        suggestedTitle = try c.decodeIfPresent(String.self, forKey: .suggestedTitle) ?? ""
        suggestedFolder = try c.decodeIfPresent(String.self, forKey: .suggestedFolder) ?? ""
        folderWasInvalid = try c.decodeIfPresent(Bool.self, forKey: .folderWasInvalid) ?? false
        confirmedTitle = try c.decodeIfPresent(String.self, forKey: .confirmedTitle)
        confirmedFolder = try c.decodeIfPresent(String.self, forKey: .confirmedFolder)
        notePath = try c.decodeIfPresent(String.self, forKey: .notePath)
        stepRetries = try c.decodeIfPresent(Int.self, forKey: .stepRetries) ?? 0
        failedStage = try c.decodeIfPresent(MeetingState.self, forKey: .failedStage)
        errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
    }
}

/// Ошибки пайплайна встречи; сообщения пригодны для показа в UI.
enum MeetingError: LocalizedError, Equatable {
    case noVault
    case noTranscriptionProvider
    case noChatProvider
    case audioFileMissing(String)
    case emptyTranscript
    case noteWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVault:
            return "Откройте vault: заметка встречи сохраняется в него."
        case .noTranscriptionProvider:
            return "Нет доступного провайдера транскрипции. Добавьте API-ключ (OpenAI/Deepgram/AssemblyAI/Gemini) или настройте локальный."
        case .noChatProvider:
            return "Нет доступного чат-провайдера для саммари. Добавьте API-ключ или настройте локальную модель."
        case let .audioFileMissing(name):
            return "Аудиофайл записи не найден: \(name)"
        case .emptyTranscript:
            return "Транскрипция вернула пустой текст — нечего оформлять."
        case let .noteWriteFailed(detail):
            return "Не удалось записать заметку: \(detail)"
        }
    }
}
