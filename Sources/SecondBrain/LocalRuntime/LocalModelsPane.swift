// LocalModelsPane.swift — UI управления локальными моделями (задача 09).
//
// Живёт в разделе «Настройки» (задача 17 добавит остальные настройки вокруг):
// статус рантайма Ollama + запуск/останов, установка (если бинаря нет —
// ollama.com/brew, не молчаливый фейл), список установленных моделей,
// скачивание с прогрессом из NDJSON-стрима /api/pull, удаление,
// рекомендуемый стартовый набор. Задача 10 добавит сюда секцию Whisper.

import SwiftUI

/// Состояние экрана локальных моделей.
@MainActor
final class LocalModelsViewModel: ObservableObject {
    @Published private(set) var models: [OllamaModel] = []
    /// Прогресс активных скачиваний: имя модели → доля 0…1 (nil в fraction —
    /// этап без размера, показываем неопределённый спиннер).
    @Published private(set) var pulls: [String: Double?] = [:]
    @Published var pullModelName: String = ""
    @Published var lastError: String?

    let manager: OllamaManager
    private let client: OllamaClient
    private var pullTasks: [String: Task<Void, Never>] = [:]

    init(manager: OllamaManager) {
        self.manager = manager
        self.client = OllamaClient(baseURL: manager.baseURL)
    }

    var isInstalled: Bool { manager.isInstalled }

    func refresh() async {
        await manager.refreshStatus()
        guard manager.status == .runningSpawned || manager.status == .runningExternal else {
            models = []
            return
        }
        do {
            models = try await client.installedModels()
        } catch {
            lastError = describe(error)
        }
    }

    /// Явный запуск рантайма кнопкой (обычно он ленивый — при первом запросе).
    func startRuntime() async {
        do {
            try await manager.ensureRunning()
            await refresh()
        } catch {
            lastError = describe(error)
        }
    }

    func stopRuntime() {
        manager.stopNow()
        models = []
    }

    /// Скачивание модели с прогрессом; UI не блокируется (фоновый Task).
    func pull(_ name: String) {
        let model = name.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, pullTasks[model] == nil else { return }
        // updateValue, не subscript: у словаря значений Double? присваивание
        // nil через subscript УДАЛЯЕТ ключ, а нам нужно «прогресс неизвестен».
        pulls.updateValue(nil, forKey: model) // этап «манифест»
        pullTasks[model] = Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.ensureRunning()
                try await client.pull(model: model) { progress in
                    Task { @MainActor [weak self] in
                        self?.pulls.updateValue(progress.fraction, forKey: model)
                    }
                }
                manager.markUsed()
            } catch {
                lastError = describe(error)
            }
            pulls.removeValue(forKey: model)
            pullTasks.removeValue(forKey: model)
            await refresh()
        }
    }

    func cancelPull(_ name: String) {
        pullTasks[name]?.cancel()
        pullTasks.removeValue(forKey: name)
        pulls.removeValue(forKey: name)
    }

    func delete(_ model: OllamaModel) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.delete(model: model.name)
                await refresh()
            } catch {
                lastError = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct LocalModelsPane: View {
    @ObservedObject var viewModel: LocalModelsViewModel
    @ObservedObject var manager: OllamaManager
    /// Секция Whisper (задача 10).
    @ObservedObject var whisperViewModel: WhisperModelsViewModel

    var body: some View {
        Form {
            runtimeSection
            if viewModel.isInstalled || manager.status != .stopped {
                modelsSection
                recommendedSection
                pullSection
            } else {
                installSection
            }
            WhisperModelsSection(viewModel: whisperViewModel,
                                 provider: whisperViewModel.provider)
        }
        .formStyle(.grouped)
        .task { await viewModel.refresh() }
        .alert(
            "Локальные модели",
            isPresented: Binding(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.lastError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(viewModel.lastError ?? "") }
        )
    }

    // MARK: - Секции

    private var runtimeSection: some View {
        Section("Рантайм Ollama") {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(manager.status.label)
                Spacer()
                switch manager.status {
                case .stopped:
                    Button("Запустить") {
                        Task { await viewModel.startRuntime() }
                    }
                    .disabled(!viewModel.isInstalled)
                case .runningSpawned:
                    Button("Остановить сейчас") { viewModel.stopRuntime() }
                case .runningExternal:
                    Text("запущен не нами")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .starting:
                    ProgressView().controlSize(.small)
                }
            }
            Text("Запускается лениво при первом обращении; гасится после 10 минут простоя и при выходе из приложения. Чужой сервер не трогаем.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var installSection: some View {
        Section("Установка") {
            Label("Ollama не найден на этом Mac.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            HStack {
                Button("Открыть ollama.com") {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                }
                Text("или")
                    .foregroundStyle(.secondary)
                Text("brew install ollama")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var modelsSection: some View {
        Section("Установленные модели") {
            if viewModel.models.isEmpty {
                Text(manager.status == .stopped
                     ? "Запустите рантайм, чтобы увидеть список."
                     : "Моделей пока нет — скачайте из набора ниже.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.models) { model in
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.name)
                        if let detail = model.detailLine {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        viewModel.delete(model)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recommendedSection: some View {
        Section("Рекомендуемый набор") {
            ForEach(RecommendedOllamaModel.starterPack, id: \.name) { recommended in
                HStack {
                    VStack(alignment: .leading) {
                        Text(recommended.name)
                        Text(recommended.purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    pullControl(for: recommended.name)
                }
            }
        }
    }

    private var pullSection: some View {
        Section("Скачать другую модель") {
            HStack {
                TextField("Имя модели (например llama3.3:70b)", text: $viewModel.pullModelName)
                    .textFieldStyle(.roundedBorder)
                Button("Скачать") {
                    viewModel.pull(viewModel.pullModelName)
                    viewModel.pullModelName = ""
                }
                .disabled(viewModel.pullModelName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(Array(viewModel.pulls.keys).sorted(), id: \.self) { name in
                if !RecommendedOllamaModel.starterPack.contains(where: { $0.name == name }) {
                    HStack {
                        Text(name)
                        Spacer()
                        pullControl(for: name)
                    }
                }
            }
        }
    }

    /// Кнопка скачивания / прогресс / галка «установлена» для одной модели.
    @ViewBuilder
    private func pullControl(for name: String) -> some View {
        if viewModel.models.contains(where: { $0.name == name || $0.name.hasPrefix(name + ":") }) {
            Label("установлена", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .labelStyle(.iconOnly)
        } else if let fraction = viewModel.pulls[name] {
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                    Text("\(Int(fraction * 100)) %")
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    viewModel.cancelPull(name)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
        } else {
            Button("Скачать") { viewModel.pull(name) }
                .disabled(!viewModel.isInstalled && manager.status == .stopped)
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .stopped: return .secondary.opacity(0.5)
        case .starting: return .orange
        case .runningSpawned, .runningExternal: return .green
        }
    }
}
