// GitHubClient.swift — тонкий HTTP-клиент GitHub (задачи 36, 37).
//
// Переехал из PRWatcher.swift при расширении под code review: один клиент на
// все GitHub-вызовы приложения. Транспорт инжектируется (perform) — тесты
// проверяют заголовки и разбор ответов без сети. Токен — Keychain, запись
// «github-token» (PRWatcher.githubTokenID); для postComment нужен токен со
// scope записи, читающие вызовы работают и без токена (лимит 60 req/ч).
//
// Осознанное отклонение от текста задачи 37: постраничный files(...) НЕ
// реализован — список затронутых файлов тривиально извлекается из самого
// diff (CodeReviewInput.splitByFile), а у отдельного API нет потребителя.

import Foundation

/// PR из ответа GitHub — только нужные пайплайну поля.
struct GitHubPullRequest: Codable, Equatable {
    let number: Int
    let title: String
    let user: Author
    let htmlURL: String
    let diffURL: String

    struct Author: Codable, Equatable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case number, title, user
        case htmlURL = "html_url"
        case diffURL = "diff_url"
    }

    /// Payload триггера ({{trigger_payload}}): всё, что нужно промпту ревью.
    var payloadText: String {
        """
        PR #\(number): \(title)
        Автор: \(user.login)
        URL: \(htmlURL)
        diff: \(diffURL)
        """
    }
}

/// Тонкий HTTP-клиент GitHub API.
struct GitHubClient {
    enum PullsResponse: Equatable {
        /// 304: список не менялся с прошлого ETag — тишина, лимит сэкономлен.
        case notModified
        case ok(pulls: [GitHubPullRequest], etag: String?, rateLimitRemaining: Int?)
    }

    enum GitHubError: LocalizedError, Equatable {
        case badStatus(code: Int)
        /// Постинг без токена отбивается ДО сетевого вызова.
        case noToken

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "GitHub-токен не задан — Настройки → «Инструменты». Для комментария нужен токен с правом записи (scope repo)."
            case .badStatus(let code):
                switch code {
                case 401:
                    return "GitHub: токен недействителен (код 401). Проверьте его в Настройках → «Инструменты»."
                case 404:
                    return "GitHub: PR не найден или нет доступа (код 404)."
                case 403, 429:
                    return "GitHub: превышен rate limit (код \(code)). Добавьте токен в Настройках → «Инструменты»."
                default:
                    return "GitHub: запрос не удался (код \(code))."
                }
            }
        }
    }

    /// Транспорт (дефолт — URLSession.shared).
    var perform: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    // MARK: - Чтение (задача 36: PR-watch)

    /// Открытые PR репозитория. etag — от прошлого успешного ответа.
    func openPulls(owner: String, repo: String,
                   etag: String?, token: String?) async throws -> PullsResponse {
        var request = makeRequest(
            url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls?state=open")!,
            token: token)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, http) = try await perform(request)
        if http.statusCode == 304 { return .notModified }
        try ensureSuccess(http)
        let pulls = try JSONDecoder().decode([GitHubPullRequest].self, from: data)
        let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            .flatMap(Int.init)
        return .ok(pulls: pulls,
                   etag: http.value(forHTTPHeaderField: "etag"),
                   rateLimitRemaining: remaining)
    }

    // MARK: - Чтение (задача 37: code review)

    /// Метаданные одного PR — для /review по ссылке (title/автор/diff_url).
    func pullRequest(owner: String, repo: String, number: Int,
                     token: String?) async throws -> GitHubPullRequest {
        let request = makeRequest(
            url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)")!,
            token: token)
        let (data, http) = try await perform(request)
        try ensureSuccess(http)
        return try JSONDecoder().decode(GitHubPullRequest.self, from: data)
    }

    /// Полный diff PR. Сначала API-эндпоинт с Accept diff (работает и для
    /// приватных репозиториев), но на диффах больше 20 000 строк GitHub
    /// отвечает 406 «diff exceeded the maximum number of lines» — тогда
    /// фолбэк на web-URL `…/pull/N.diff`, у которого этого лимита нет
    /// (без Authorization: web-URL аутентифицируется сессией, не API-токеном;
    /// ограничение — приватный репозиторий с гигантским диффом не поддержан).
    func diff(owner: String, repo: String, number: Int,
              token: String?) async throws -> String {
        do {
            return try await diff(
                url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)")!,
                token: token)
        } catch GitHubError.badStatus(406) {
            return try await diff(
                url: URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number).diff")!,
                token: nil)
        }
    }

    /// Diff по прямому URL (diff_url из payload PR-watch — метаданные уже
    /// есть, отдельный запрос не нужен; подсказка задачи 37).
    func diff(url: URL, token: String?) async throws -> String {
        var request = makeRequest(url: url, token: token)
        request.setValue("application/vnd.github.v3.diff", forHTTPHeaderField: "Accept")
        // Diff большого PR качается дольше JSON-метаданных.
        request.timeoutInterval = 60
        let (data, http) = try await perform(request)
        try ensureSuccess(http)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Запись (задача 37: комментарий в PR)

    /// Сводный комментарий к PR (issue-комментарий — PR является issue).
    /// Write-операция: без токена не выполняется вовсе (.noToken).
    func postComment(owner: String, repo: String, number: Int,
                     body: String, token: String?) async throws {
        guard let token, !token.isEmpty else { throw GitHubError.noToken }
        var request = makeRequest(
            url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)/comments")!,
            token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["body": body])
        let (_, http) = try await perform(request)
        try ensureSuccess(http) // GitHub отвечает 201 Created
    }

    // MARK: - Внутренности

    private func makeRequest(url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func ensureSuccess(_ http: HTTPURLResponse) throws {
        guard (200...299).contains(http.statusCode) else {
            throw GitHubError.badStatus(code: http.statusCode)
        }
    }
}
