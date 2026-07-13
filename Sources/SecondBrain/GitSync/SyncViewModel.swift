// SyncViewModel.swift — состояние git-синхронизации vault (задача 16).
//
// Единственный владелец мутабельного состояния синка (паттерн CONVENTIONS.md).
// Поток данных:
//   VaultManager.vaultURL → attach() → GitClient(корень vault)
//        ↓
//   refresh(): доступность git → корень репо? → status/log/remotes
//        ↓
//   @Published состояние → индикатор в тулбаре + панель GitSyncPanel
//
// Операции (commit+push, pull, init…) защищены от параллельного запуска
// флагом isBusy; сами git-вызовы дополнительно сериализует GitClient.
// Авто-бэкап: таймер тикает раз в 30 с, решение принимает чистый AutoBackup
// (isDue + plan) — ошибки пуша не теряются (баннер lastError), повторные
// прогоны не дублируют коммиты.

import SwiftUI

@MainActor
final class SyncViewModel: ObservableObject {

    /// Крупное состояние: что показывать в панели.
    enum RepoState: Equatable {
        case noVault                    // vault не открыт
        case checking                   // определяем состояние после attach
        case gitUnavailable(String)     // git не найден/не работает
        case notARepo                   // предложить «Включить синхронизацию»
        case ready                      // репозиторий, работаем
    }

    /// Предупреждение «в URL remote зашит токен» + данные для починки.
    struct RemoteCredentialWarning: Equatable {
        let remoteName: String
        /// Сам секрет — показываем пользователю, чтобы сохранил его в
        /// менеджере паролей ДО удаления из URL. Приложение его не хранит.
        let credential: String
        let cleanURL: String
    }

    @Published private(set) var repoState: RepoState = .noVault
    @Published private(set) var status: GitStatus?
    @Published private(set) var history: [GitCommit] = []
    @Published private(set) var remotes: [GitRemote] = []
    /// Идёт операция; параллельные запрещены (index.lock + понятный UI).
    @Published private(set) var isBusy = false
    /// Подпись текущей операции для прогресс-индикации («Push…», «Pull…»).
    @Published private(set) var busyLabel: String?
    /// Последняя ошибка — баннер в панели; не глотаем (CONVENTIONS.md).
    @Published var lastError: String?
    /// Конфликтные файлы последнего pull (merge уже прерван) — драйвит диалог
    /// «принять свои / принять удалённые / открыть в Finder».
    @Published var conflictFiles: [String]?
    @Published private(set) var credentialWarning: RemoteCredentialWarning?
    /// Рекомендованные записи .gitignore, которых ещё нет в vault.
    @Published private(set) var missingIgnoreEntries: [String] = []
    /// Черновик сообщения коммита в панели; пустой → авто-сообщение бэкапа.
    @Published var commitMessageDraft = ""
    /// Интервал авто-бэкапа в минутах; 0 — выключен. Источник истины —
    /// SettingsStore (задача 17), двустороннюю связку держит AppModel.
    @Published var autoBackupMinutes = 0
    /// Время последнего успешного авто-бэкапа (для строки статуса).
    @Published private(set) var lastBackupDate: Date?

    /// Варианты интервала авто-бэкапа для UI (минуты; 0 — выключен).
    static let autoBackupChoices = [0, 5, 15, 30, 60]

    private(set) var client: GitClient?
    private var vaultURL: URL?
    private var timer: Timer?
    /// Последняя ПОПЫТКА авто-бэкапа (не успех): неудачный push не должен
    /// превращаться в ретрай каждые 30 секунд.
    private var lastAutoBackupAttempt: Date?

    init() {
        // Тик раз в 30 с; сам решает, пора ли (AutoBackup.isDue) — так смена
        // интервала в настройках не требует пересоздания таймера.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.autoBackupTick(now: Date()) }
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Привязка к vault

    /// Смена vault: новый клиент + свежий статус. nil — vault закрыт.
    func attach(vaultURL: URL?) {
        guard vaultURL != self.vaultURL || client == nil else { return }
        self.vaultURL = vaultURL
        conflictFiles = nil
        lastError = nil
        history = []
        remotes = []
        status = nil
        credentialWarning = nil
        missingIgnoreEntries = []
        guard let vaultURL else {
            client = nil
            repoState = .noVault
            return
        }
        client = GitClient(repoURL: vaultURL)
        repoState = .checking
        Task { await refresh() }
    }

    // MARK: - Обновление состояния

    /// Перечитывает всё состояние; fetching=true — сначала git fetch
    /// (сетевой), чтобы ahead/behind были актуальны.
    func refresh(fetching: Bool = false) async {
        guard let client else { return }
        do {
            try await client.ensureAvailable()
        } catch {
            repoState = .gitUnavailable(describe(error))
            return
        }
        guard await client.isRepository() else {
            repoState = .notARepo
            return
        }
        if fetching {
            do {
                try await client.fetch()
            } catch {
                lastError = describe(error) // fetch не удался — статус всё равно покажем
            }
        }
        await reloadSnapshot()
        repoState = .ready
    }

    /// Загружает status/log/remotes и производные предупреждения.
    private func reloadSnapshot() async {
        guard let client else { return }
        do {
            status = try await client.status()
            history = try await client.log(limit: 20)
            remotes = try await client.remotes()
        } catch {
            lastError = describe(error)
        }
        credentialWarning = remotes.lazy.compactMap { remote -> RemoteCredentialWarning? in
            guard let credential = GitRemoteURL.embeddedCredential(in: remote.url) else { return nil }
            return RemoteCredentialWarning(remoteName: remote.name,
                                           credential: credential,
                                           cleanURL: GitRemoteURL.strippingCredential(remote.url))
        }.first
        reloadIgnoreAdvice()
    }

    private func reloadIgnoreAdvice() {
        guard let vaultURL else { return }
        let content = (try? String(contentsOf: vaultURL.appendingPathComponent(".gitignore"),
                                   encoding: .utf8)) ?? ""
        missingIgnoreEntries = GitignoreAdvisor.missingEntries(in: content)
    }

    // MARK: - Операции

    /// «Включить синхронизацию»: git init + первый коммит (+ remote, если задан).
    func enableSync(remoteURL: String) {
        perform("Инициализация…") { client in
            try await client.initRepository()
            _ = try await client.commitAll(message: AutoBackup.commitMessage(for: Date()))
            let trimmed = remoteURL.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                try await client.addRemote(name: "origin", url: trimmed)
                try await client.push()
            }
            await MainActor.run { self.repoState = .ready }
        }
    }

    /// Commit всех изменений + push (если есть remote). Пустое сообщение —
    /// авто-формат «vault backup: <дата>».
    func commitAndPush() {
        let draft = commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = draft.isEmpty ? AutoBackup.commitMessage(for: Date()) : draft
        perform("Commit + Push…") { client in
            _ = try await client.commitAll(message: message)
            if try await !client.remotes().isEmpty {
                try await client.push()
            }
            await MainActor.run { self.commitMessageDraft = "" }
        }
    }

    /// Pull (merge). Конфликт ловим отдельно: merge уже прерван клиентом,
    /// показываем диалог выбора стороны.
    func pull() {
        perform("Pull…") { client in
            try await client.pull()
        }
    }

    /// Повторный pull с разрешением конфликтов в пользу стороны.
    func resolveConflicts(preferring side: GitMergeSide) {
        conflictFiles = nil
        perform("Pull (разрешение конфликтов)…") { client in
            try await client.pull(resolving: side)
        }
    }

    /// Починка remote с токеном в URL: переписываем URL без секрета.
    /// Сам токен пользователь уже видел в панели (сохранить в Keychain — его
    /// ответственность; мы секреты не храним).
    func fixRemoteCredential() {
        guard let warning = credentialWarning else { return }
        perform("Правка remote…") { client in
            try await client.setRemoteURL(name: warning.remoteName, url: warning.cleanURL)
        }
    }

    /// Дописывает выбранные записи в .gitignore vault (файл только дополняется).
    func appendIgnoreEntries(_ entries: [String]) {
        guard let vaultURL, !entries.isEmpty else { return }
        let url = vaultURL.appendingPathComponent(".gitignore")
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try GitignoreAdvisor.appending(entries, to: current)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
        }
        reloadIgnoreAdvice()
        Task { await reloadSnapshot() }
    }

    /// Показать конфликтные файлы в Finder (пользователь мержит руками).
    func revealInFinder(paths: [String]) {
        guard let vaultURL else { return }
        let urls = paths.map { vaultURL.appendingPathComponent($0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Авто-бэкап

    /// Тик таймера. Публичный с инъекцией «сейчас» — вызывается и из тестов.
    func autoBackupTick(now: Date) async {
        guard repoState == .ready, !isBusy, let client else { return }
        guard AutoBackup.isDue(now: now,
                               lastAttempt: lastAutoBackupAttempt,
                               interval: TimeInterval(autoBackupMinutes * 60)) else { return }
        lastAutoBackupAttempt = now
        isBusy = true
        busyLabel = "Авто-бэкап…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        do {
            let current = try await client.status()
            let plan = AutoBackup.plan(status: current, hasRemote: !remotes.isEmpty)
            if plan.needsCommit {
                _ = try await client.commitAll(message: AutoBackup.commitMessage(for: now))
            }
            if plan.needsPush {
                try await client.push()
            }
            if plan != .nothing {
                lastBackupDate = now
                await reloadSnapshot()
            }
        } catch {
            // Ошибка (обычно push без сети) — баннер; коммит уже сделан и не
            // потеряется: следующий прогон увидит ahead > 0 и допушит.
            lastError = describe(error)
        }
    }

    // MARK: - Каркас операций

    /// Общий каркас: занятость, ошибки, обновление снимка после операции.
    private func perform(_ label: String,
                         _ operation: @escaping (GitClient) async throws -> Void) {
        guard !isBusy, let client else { return }
        isBusy = true
        busyLabel = label
        Task {
            defer {
                isBusy = false
                busyLabel = nil
            }
            do {
                try await operation(client)
            } catch let error as GitError {
                if case .mergeConflict(let files) = error {
                    conflictFiles = files
                } else {
                    lastError = describe(error)
                }
            } catch {
                lastError = describe(error)
            }
            await reloadSnapshot()
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
