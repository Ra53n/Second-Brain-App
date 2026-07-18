// MeetingsPane.swift — UI раздела «Встречи» (задачи 06 + 11, редизайн 41):
// компактная панель записи (кнопка + меню источника + название), список
// записей с плеером и статусом пайплайна «запись → заметка», нижняя
// статус-строка (стиль Claude Code, как в чате): провайдер транскрипции
// и переход к настройкам встреч. Правила раскладки и полные статусы
// разрешений переехали в Settings → «Встречи»; здесь остаются только
// предупреждения, когда что-то реально мешает записи/транскрипции.

import SwiftUI

struct MeetingsPane: View {
    @ObservedObject var viewModel: MeetingsViewModel
    /// Роутер — ObservableObject: смена назначения обновляет чип провайдера.
    @ObservedObject var functionRouter: FunctionRouter
    @Environment(\.openSettings) private var openSettings
    /// Тик пересчёта доступности провайдеров: ключи/модели меняются в окне
    /// настроек — перечитываем при возврате фокуса (паттерн чата).
    @State private var availabilityTick = 0

    init(viewModel: MeetingsViewModel) {
        self.viewModel = viewModel
        self.functionRouter = viewModel.functionRouter
    }

    private var routePresenter: TranscriptionRoutePresenter {
        TranscriptionRoutePresenter(router: viewModel.functionRouter)
    }

    var body: some View {
        VStack(spacing: 0) {
            recordingControls
                .padding()
            Divider()
            recordingList
            Divider()
            statusBar
        }
        .onAppear { viewModel.reloadAfterVaultChange() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in
            availabilityTick &+= 1
        }
        .alert(
            "Запись",
            isPresented: Binding(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.lastError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(viewModel.lastError?.errorDescription ?? "") }
        )
        .alert(
            "Пайплайн встречи",
            isPresented: Binding(
                get: { viewModel.pipelineError != nil },
                set: { if !$0 { viewModel.pipelineError = nil } }
            ),
            actions: {
                // Ошибка про отсутствие провайдера — ведём чинить в настройки,
                // а не бросаем в тупике с одним «OK» (задача 41).
                if let tab = MeetingErrorNavigation.settingsTab(
                    forErrorText: viewModel.pipelineError ?? "") {
                    Button("Открыть настройки") {
                        viewModel.pipelineError = nil
                        SettingsTabRouter.open(tab, openSettings: { openSettings() })
                    }
                }
                Button("OK", role: .cancel) {}
            },
            message: { Text(viewModel.pipelineError ?? "") }
        )
        .sheet(item: $viewModel.titleDialog) { context in
            TitleConfirmationView(context: context, viewModel: viewModel)
        }
    }

    // MARK: - Панель записи

    @ViewBuilder
    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = viewModel.session {
                ActiveRecordingView(session: session, viewModel: viewModel)
            } else {
                idleControls
            }
        }
    }

    /// Панель до старта: одна строка «Записать + источник + название»;
    /// ниже — только реальные предупреждения (разрешения, нет провайдера).
    @ViewBuilder
    private var idleControls: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.startRecording() }
            } label: {
                Label("Записать", systemImage: "record.circle")
                    .foregroundStyle(.red)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            // Компактное меню источника вместо сегментед-пикера на всю ширину:
            // дефолт настраивается в Settings → «Встречи», здесь — разовый выбор.
            Menu {
                Picker("Источник", selection: $viewModel.sourceChoice) {
                    ForEach(RecordingSource.allCases) { source in
                        Label(source.title, systemImage: source.systemImage).tag(source)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(viewModel.sourceChoice.title,
                      systemImage: viewModel.sourceChoice.systemImage)
            }
            .fixedSize()
            .help("Источник этой записи: микрофон, системный звук или оба (две дорожки)")

            // Название до записи: пайплайн пройдёт без диалога подтверждения.
            TextField("Название (пусто — предложит ИИ)", text: $viewModel.presetTitle)
                .textFieldStyle(.roundedBorder)
        }

        permissionWarnings
        providerBanner
    }

    /// Предупреждения о разрешениях — ТОЛЬКО когда выбранный источник их
    /// требует и они реально не выданы/не поддержаны. Полные статусы —
    /// в Settings → «Встречи» (задача 41).
    @ViewBuilder
    private var permissionWarnings: some View {
        if viewModel.sourceChoice.needsMicrophone && viewModel.micAuthorized == false {
            Label("Микрофон запрещён — разрешите в Системных настройках → Конфиденциальность",
                  systemImage: "mic.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if viewModel.sourceChoice.needsSystemAudio && !MeetingsViewModel.systemAudioSupported {
            Label("Запись системного звука требует macOS 14.4+ — выберите «Микрофон»",
                  systemImage: "speaker.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Баннер «нечем транскрибировать»: записать можно, но пайплайн упрётся.
    /// Кнопки ведут в оба места, где это чинится.
    @ViewBuilder
    private var providerBanner: some View {
        // availabilityTick форсит пересчёт при возврате из окна настроек.
        if availabilityTick >= 0 && !routePresenter.hasAvailableProvider {
            VStack(alignment: .leading, spacing: 6) {
                Label("Нет провайдера транскрипции: скачайте локальную модель Whisper или добавьте API-ключ.",
                      systemImage: "waveform.badge.exclamationmark")
                    .foregroundStyle(.orange)
                HStack(spacing: 8) {
                    Button("Локальные модели…") {
                        SettingsTabRouter.open(.localModels, openSettings: { openSettings() })
                    }
                    Button("API-ключи…") {
                        SettingsTabRouter.open(.providers, openSettings: { openSettings() })
                    }
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
    }

    // MARK: - Список записей

    @ViewBuilder
    private var recordingList: some View {
        if viewModel.recordings.isEmpty {
            ContentUnavailableView {
                Label("Нет записей", systemImage: "mic")
            } description: {
                Text(viewModel.recordingsDirectory == nil
                     ? "Откройте vault, чтобы записывать встречи."
                     : "Записи появятся в Meetings/_recordings вашего vault.")
            }
        } else {
            List(viewModel.recordings) { item in
                RecordingRow(item: item,
                             isPlaying: viewModel.playingURL == item.playbackURL,
                             viewModel: viewModel) {
                    viewModel.togglePlayback(of: item)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Статус-строка (задача 41, стиль settingsBar чата)

    /// Нижняя строка раздела: чип провайдера транскрипции (меню переключения)
    /// и переход к настройкам встреч (правила раскладки, папка, дефолт-источник).
    private var statusBar: some View {
        HStack(spacing: 4) {
            transcriptionMenu
            Divider().frame(height: 12)
            Button {
                SettingsTabRouter.open(.meetings, openSettings: { openSettings() })
            } label: {
                Label("Правила и папка…", systemImage: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .help("Настройки встреч: правила раскладки для ИИ, папка заметок, источник по умолчанию")
            Spacer()
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.accessoryBar)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Меню провайдера транскрипции: «Авто» + все провайдеры со способностью
    /// transcription (недоступные видны, но задизейблены) + точки входа
    /// в настройку ключей/локальных моделей.
    private var transcriptionMenu: some View {
        let presenter = routePresenter
        let isAuto = viewModel.functionRouter.assignment(for: .transcription) == nil
        return Menu {
            Button {
                presenter.selectAuto()
            } label: {
                if isAuto {
                    Label("Авто (первый доступный)", systemImage: "checkmark")
                } else {
                    Text("Авто (первый доступный)")
                }
            }
            Divider()
            ForEach(presenter.choices) { choice in
                Button {
                    presenter.select(choice.id)
                } label: {
                    if choice.isSelected {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
                .disabled(!choice.isAvailable)
            }
            Divider()
            Button("API-ключи…") {
                SettingsTabRouter.open(.providers, openSettings: { openSettings() })
            }
            Button("Локальные модели…") {
                SettingsTabRouter.open(.localModels, openSettings: { openSettings() })
            }
        } label: {
            Label(presenter.chipTitle, systemImage: "waveform")
                .foregroundStyle(presenter.hasAvailableProvider ? Color.secondary : .orange)
        }
        .help("Каким провайдером транскрибировать встречи; «Авто» — первый доступный")
    }
}

/// Статус и действия пайплайна встречи для строки записи.
private struct PipelineStatusView: View {
    let item: MeetingsViewModel.RecordingItem
    @ObservedObject var meetingStore: MeetingStore
    let viewModel: MeetingsViewModel

    var body: some View {
        let context = viewModel.meeting(for: item)
        HStack(spacing: 8) {
            switch (context?.state, context?.status) {
            case (nil, _), (.recorded, _):
                Button("Транскрибировать") { viewModel.runPipeline(for: item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case (.done, _):
                if let context {
                    Button {
                        viewModel.openNote(context)
                    } label: {
                        Label("Открыть заметку", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case (.failed, _):
                Label(context?.errorText ?? "Ошибка", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Повторить") { viewModel.runPipeline(for: item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case (.awaitingTitle, _):
                Button("Подтвердить название…") {
                    if let context { viewModel.titleDialog = context }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case (_, .paused):
                Button {
                    viewModel.runPipeline(for: item)
                } label: {
                    Label("Продолжить (\(context?.state.label ?? ""))", systemImage: "play")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            default:
                ProgressView()
                    .controlSize(.small)
                Text(context?.state.label ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Диалог подтверждения названия/папки (пайплайн стоит в awaitingTitle).
private struct TitleConfirmationView: View {
    let context: MeetingContext
    let viewModel: MeetingsViewModel
    @State private var title: String = ""
    @State private var folder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Оформление встречи")
                .font(.headline)
            if context.folderWasInvalid {
                Label("ИИ предложил несуществующую папку — подставлена папка по умолчанию.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TextField("Название встречи", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Папка в vault", text: $folder)
                .textFieldStyle(.roundedBorder)
            if !context.summary.isEmpty {
                ScrollView {
                    Text(context.summary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Spacer()
                Button("Отмена") { viewModel.titleDialog = nil }
                Button("Создать заметку") {
                    viewModel.confirmTitle(title, folder: folder)
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460)
        .onAppear {
            title = context.effectiveTitle
            folder = context.effectiveFolder.isEmpty
                ? MeetingNoteWriter.defaultFolder(for: context.recordedAt)
                : context.effectiveFolder
        }
    }
}

/// Активная запись: таймер, индикаторы уровня, пауза/стоп.
private struct ActiveRecordingView: View {
    @ObservedObject var session: RecordingSession
    let viewModel: MeetingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.state == .paused ? Color.orange : Color.red)
                    .frame(width: 10, height: 10)
                Text(session.state == .paused ? "Пауза" : "Идёт запись")
                    .font(.headline)
                Spacer()
                Text(Self.format(session.elapsed))
                    .font(.title2.monospacedDigit())
            }

            if session.source.needsMicrophone {
                LevelMeter(label: "Микрофон", level: session.micLevel)
            }
            if session.source.needsSystemAudio {
                LevelMeter(label: "Система", level: session.systemLevel)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.togglePause()
                } label: {
                    Label(session.state == .paused ? "Продолжить" : "Пауза",
                          systemImage: session.state == .paused ? "play.fill" : "pause.fill")
                }
                Button {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("Стоп", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                Spacer()
            }
        }
    }

    /// «мм:сс» до часа, дальше «ч:мм:сс».
    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

/// Полоска уровня сигнала 0…1.
private struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(level > 0.85 ? Color.red : Color.green)
                        .frame(width: geometry.size.width * CGFloat(level))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}

/// Строка статуса разрешения: галка/крест/вопрос + текст. Internal (задача 41):
/// полные статусы разрешений показывает Settings → «Встречи».
struct PermissionRow: View {
    let granted: Bool?  // nil — ещё не известно
    let grantedText: String
    let deniedText: String
    let unknownText: String

    var body: some View {
        switch granted {
        case true:
            Label(grantedText, systemImage: "checkmark.circle")
        case false:
            Label(deniedText, systemImage: "xmark.circle")
                .foregroundStyle(.orange)
        default:
            Label(unknownText, systemImage: "questionmark.circle")
        }
    }
}

/// Строка списка записей: имя, дата, длительность, режим, плеер + пайплайн.
private struct RecordingRow: View {
    let item: MeetingsViewModel.RecordingItem
    let isPlaying: Bool
    let viewModel: MeetingsViewModel
    let togglePlay: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let date = item.date {
                        Text(Self.dateFormatter.string(from: date))
                    }
                    if let duration = item.duration, duration > 0 {
                        Text(ActiveRecordingView.format(duration))
                    }
                    if let source = item.source {
                        Text(source.title)
                    }
                    if item.trackCount > 1 {
                        Text("\(item.trackCount) дорожки")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // В узкой колонке HStack давал каждому тексту минимум ширины
                // и они заворачивались в столбики — обрезаем в одну строку.
                .lineLimit(1)
            }
            Spacer()
            PipelineStatusView(item: item,
                               meetingStore: viewModel.meetingStore,
                               viewModel: viewModel)
        }
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.playbackURL])
            }
        }
    }
}
