// WhisperModelsSection.swift — секция Whisper-моделей в экране локальных
// моделей (задача 10): тот же UX скачивания, что у Ollama-секций (прогресс,
// отмена, удаление), плюс выбор активной модели и состояние движка в памяти.

import SwiftUI
import WhisperKit

/// Состояние секции Whisper: установленное, загрузки, выбор.
@MainActor
final class WhisperModelsViewModel: ObservableObject {
    @Published private(set) var installed: [String] = []
    /// Прогресс активных скачиваний: вариант → доля 0…1.
    @Published private(set) var downloads: [String: Double] = [:]
    @Published var lastError: String?

    let provider: WhisperKitProvider
    private let downloadBase: URL
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(provider: WhisperKitProvider,
         downloadBase: URL = WhisperModelStorage.defaultDownloadBase) {
        self.provider = provider
        self.downloadBase = downloadBase
        refresh()
    }

    func refresh() {
        installed = WhisperModelStorage.installedVariants(base: downloadBase)
    }

    /// Скачивание модели с прогрессом (WhisperKit сам ходит на Hugging Face,
    /// кэш направлен в наш Application Support).
    func download(_ variant: String) {
        guard downloadTasks[variant] == nil else { return }
        downloads[variant] = 0
        downloadTasks[variant] = Task { [weak self, downloadBase] in
            do {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: downloadBase
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.downloads[variant] = progress.fractionCompleted
                    }
                }
            } catch is CancellationError {
                // отмена пользователем — не ошибка
            } catch {
                self?.lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self?.downloads.removeValue(forKey: variant)
            self?.downloadTasks.removeValue(forKey: variant)
            self?.refresh()
        }
    }

    func cancelDownload(_ variant: String) {
        downloadTasks[variant]?.cancel()
    }

    func delete(_ variant: String) {
        do {
            try WhisperModelStorage.delete(variant, base: downloadBase)
        } catch {
            lastError = error.localizedDescription
        }
        // Удалили активную модель — выгружаем её из памяти.
        if provider.selectedVariant == variant {
            provider.unloadNow()
        }
        refresh()
    }

    func sizeOnDisk(_ variant: String) -> Int64 {
        WhisperModelStorage.sizeOnDisk(variant, base: downloadBase)
    }
}

/// Секции Whisper для вставки в LocalModelsPane (внутри Form).
struct WhisperModelsSection: View {
    @ObservedObject var viewModel: WhisperModelsViewModel
    @ObservedObject var provider: WhisperKitProvider

    var body: some View {
        Section("Транскрипция Whisper (локально)") {
            engineRow
            if !viewModel.installed.isEmpty {
                Picker("Активная модель", selection: $provider.selectedVariant) {
                    ForEach(viewModel.installed, id: \.self) { variant in
                        Text(variant).tag(variant)
                    }
                }
            }
        }
        Section("Whisper-модели") {
            ForEach(WhisperVariant.catalog) { variant in
                variantRow(variant)
            }
            Text("Модели хранятся в Application Support/SecondBrain/WhisperKit и скачиваются с Hugging Face при первом выборе.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert(
            "Whisper-модели",
            isPresented: Binding(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.lastError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(viewModel.lastError ?? "") }
        )
    }

    /// Состояние движка в памяти + ручная выгрузка.
    @ViewBuilder
    private var engineRow: some View {
        HStack {
            switch provider.engineState {
            case .unloaded:
                Label("Модель не загружена в память", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView().controlSize(.small)
                Text("Загрузка модели…")
            case let .ready(variant):
                Label("В памяти: \(variant) (выгрузится после простоя)",
                      systemImage: "memorychip")
            case let .transcribing(variant):
                ProgressView(value: provider.transcriptionProgress)
                    .frame(width: 120)
                Text("Транскрипция (\(variant))…")
            }
            Spacer()
            if case .ready = provider.engineState {
                Button("Выгрузить сейчас") { provider.unloadNow() }
            }
        }
    }

    @ViewBuilder
    private func variantRow(_ variant: WhisperVariant) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(variant.name)
                    if variant.name == WhisperVariant.recommendedName {
                        Text("рекомендуем")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(variant.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.installed.contains(variant.name) {
                Text(ByteCountFormatter.string(fromByteCount: viewModel.sizeOnDisk(variant.name),
                                               countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    viewModel.delete(variant.name)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            } else if let fraction = viewModel.downloads[variant.name] {
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("\(Int(fraction * 100)) %")
                    .font(.caption.monospacedDigit())
                Button {
                    viewModel.cancelDownload(variant.name)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
            } else {
                Button("Скачать") { viewModel.download(variant.name) }
            }
        }
    }
}
