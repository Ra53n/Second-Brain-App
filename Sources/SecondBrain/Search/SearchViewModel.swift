// SearchViewModel.swift — состояние поиска: запрос, результаты, жизненный цикл индекса.
//
// Поток данных:
//   $query (debounce 150 мс) → indexQueue: SearchIndex.search → main: results
//   VaultManager.$vaultURL → открыть/создать индекс vault + первичная индексация
//   VaultManager.$diskChangeTick (FSEvents) → инкрементальный refresh
//
// Все обращения к SearchIndex — ТОЛЬКО с серийной indexQueue (класс индекса не
// потокобезопасен); наружу уходят иммутабельные [SearchHit] через main.

import SwiftUI
import Combine

/// Владелец состояния поиска. Живёт один на приложение, следит за vault.
@MainActor
final class SearchViewModel: ObservableObject {

    /// Текст в поле поиска. Пустой — показывается дерево, не результаты.
    @Published var query = ""
    @Published private(set) var results: [SearchHit] = []
    /// Идёт первичная индексация vault (для индикатора в UI).
    @Published private(set) var isIndexing = false
    @Published var lastError: String?

    private weak var vaultManager: VaultManager?
    /// Единственный поток, касающийся SearchIndex (см. заголовок SearchIndex).
    private let indexQueue = DispatchQueue(label: "com.local.second-brain.search", qos: .utility)
    /// Очередь-confined состояние: ЛЮБОЙ доступ — только из indexQueue.
    /// nonisolated(unsafe) — сознательно: изоляцию обеспечивает серийная
    /// очередь, а не актор (паттерн MA: сторы на global queue).
    private nonisolated(unsafe) var index: SearchIndex?
    private var cancellables: Set<AnyCancellable> = []

    init(vaultManager: VaultManager) {
        self.vaultManager = vaultManager

        // Смена vault → новый индекс (свой файл на vault-id) + первичная индексация.
        vaultManager.$vaultURL
            .removeDuplicates()
            .sink { [weak self] url in self?.reopenIndex(for: url) }
            .store(in: &cancellables)

        // FSEvents → инкрементальный refresh; активный поиск освежается.
        vaultManager.$diskChangeTick
            .dropFirst()
            .sink { [weak self] _ in self?.refreshIndex() }
            .store(in: &cancellables)

        // Живой поиск по мере ввода (паттерн MA: debounce на $published).
        $query
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in self?.runSearch(query) }
            .store(in: &cancellables)
    }

    /// Открыть найденное: выбор файла в дереве → редактор.
    func open(_ hit: SearchHit) {
        vaultManager?.selection = hit.url
    }

    /// Команда «Пересоздать индекс» — на случай рассинхрона с vault.
    func rebuildIndex() {
        guard let root = vaultManager?.vaultURL else { return }
        isIndexing = true
        indexQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.index?.rebuild(root: root)
                Task { @MainActor in
                    self.isIndexing = false
                    self.runSearch(self.query)
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    // MARK: - Внутреннее

    private func reopenIndex(for url: URL?) {
        results = []
        guard let url else {
            indexQueue.async { [weak self] in self?.index = nil }
            return
        }
        let dbPath = SearchIndex.databaseURL(vaultID: VaultID.make(for: url)).path
        isIndexing = true
        indexQueue.async { [weak self] in
            guard let self else { return }
            do {
                let index = try SearchIndex(path: dbPath)
                try index.refresh(root: url) // первый запуск = полная индексация
                self.index = index
                Task { @MainActor in
                    self.isIndexing = false
                    self.runSearch(self.query)
                }
            } catch {
                self.index = nil
                self.publishError(error)
            }
        }
    }

    private func refreshIndex() {
        guard let root = vaultManager?.vaultURL else { return }
        indexQueue.async { [weak self] in
            guard let self, let index = self.index else { return }
            do {
                if try index.refresh(root: root) {
                    Task { @MainActor in self.runSearch(self.query) }
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    private func runSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        indexQueue.async { [weak self] in
            guard let self, let index = self.index else { return }
            do {
                let hits = try index.search(trimmed)
                Task { @MainActor in
                    // Пока искали, запрос мог измениться — не затираем свежее старым.
                    guard self.query.trimmingCharacters(in: .whitespaces) == trimmed else { return }
                    self.results = hits
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    /// Ошибки индекса не глотаем (CONVENTIONS.md) — наружу в alert.
    /// nonisolated: зовётся с indexQueue, сама прыгает на main.
    private nonisolated func publishError(_ error: Error) {
        Task { @MainActor in
            self.isIndexing = false
            self.lastError = error.localizedDescription
        }
    }
}
