// ChatToolAssembly.swift — единая точка сборки инструментов хода (задача 36).
//
// До неё логика «MCP-серверы чата + инструменты проекта + rag_search и
// маршрутизация вызовов между мостами» дублировалась в startGeneration
// (одиночный ход) и runAgentPhase (фаза FSM 35). Теперь оба пути и движок
// пайплайнов собирают инструменты здесь; порядок неизменен: MCP → проект →
// rag_search последним (маршрутизация проверяет его первым, имена не
// пересекаются — MCP-имена всегда содержат «__»).
//
// Задача 39: перед КАЖДЫМ вызовом (project и MCP) — гейт слоя разрешений:
// классификация риска (ToolPermissions) + режим чата → выполнить сразу или
// ждать подтверждения пользователя (ToolApprovalCenter). Инструменты проекта
// работают в эффективном корне чата (projectRootPath ?? глобальная настройка)
// и получают файловый контекст чата (mtime-guard, накопитель diff'ов).

import Foundation

extension ChatViewModel {
    /// Инструменты хода + единый маршрутизирующий исполнитель.
    struct AssembledTooling {
        var tools: [ToolDefinition]
        var execute: (String, String) async -> String
        /// Лимит итераций tool-цикла: с инструментами проекта выше (сценарий
        /// «прочитай 3 файла, поправь один, прогони тесты» не влезает в 6).
        var maxIterations: Int = ToolUseLoop.defaultMaxIterations
        /// Файловый контекст чата: после цикла из него вычерпываются
        /// применённые изменения (diff'ы — в сообщение хода).
        var fileOps: FileOpsContext?
        /// Эффективный корень проекта — для директивы системного промпта.
        var projectRoot: URL?
        var hasProjectTools: Bool { projectRoot != nil }
    }

    /// Лимит итераций одиночного хода при включённых инструментах проекта.
    static let projectToolsMaxIterations = 10

    /// Сборка по конфигурации чата. forceProjectTools — переопределение хода
    /// (/help включает инструменты проекта независимо от настройки чата).
    /// onRagSources — накопление источников rag_search: одиночный ход цепляет
    /// их к сообщению-заглушке прямо в ходе цикла, FSM копит в исход фазы.
    func assembleTooling(chatID: UUID,
                         configuration: ChatConfiguration,
                         ragToolDefinition: ToolDefinition?,
                         forceProjectTools: Bool = false,
                         onRagSources: @escaping ([RagSource]) -> Void) async -> AssembledTooling {
        var tools: [ToolDefinition] = []
        if !configuration.enabledMCPServerIDs.isEmpty, let bridge = mcpBridge {
            tools = await bridge.tools(configuration.enabledMCPServerIDs)
        }
        // Имена project-инструментов вычисляются на этот ход: по ним
        // executor-замыкание маршрутизирует вызовы между мостами.
        var projectNames: Set<String> = []
        let rootOverride = configuration.projectRootPath
        var projectRoot: URL?
        if configuration.projectToolsEnabled || forceProjectTools,
           let project = projectToolsBridge, project.available(rootOverride) {
            let projectTools = project.tools(rootOverride)
            projectNames = Set(projectTools.map(\.name))
            tools += projectTools
            projectRoot = project.rootURL(rootOverride)
        }
        if let ragToolDefinition { tools.append(ragToolDefinition) }

        let fileOps = projectNames.isEmpty ? nil : fileOps(for: chatID)
        let mode = configuration.permissionMode
        let mcpBridge = self.mcpBridge
        let projectBridge = self.projectToolsBridge
        let ragBridge = self.ragToolBridge
        let root = projectRoot

        return AssembledTooling(tools: tools, execute: { [weak self] name, args in
            // Гейт разрешений (задача 39): классификация → режим чата →
            // при необходимости ждём решения пользователя. rag_search и
            // read-инструменты классифицируются safe и проходят без вопросов.
            let risk = ToolRiskClassifier.classify(name: name, argumentsJSON: args)
            if ToolPermissionPolicy.requiresApproval(mode: mode, risk: risk) {
                let key = ToolRiskClassifier.operationKey(name: name, argumentsJSON: args)
                let sessionApproved = await self?.isSessionApproved(chatID: chatID, key: key) ?? false
                if !sessionApproved {
                    // Превью деталей (diff правки/команда) читает диск —
                    // вне главного потока.
                    let preview = await Task.detached(priority: .userInitiated) {
                        FileChangePreview.detail(toolName: name, argumentsJSON: args, root: root)
                    }.value
                    guard let self else {
                        return "ERROR: пользователь отклонил операцию «\(name)»"
                    }
                    let decision = await self.requestToolApproval(
                        chatID: chatID, toolName: name, risk: risk,
                        detail: preview ?? Self.compactArguments(args))
                    switch decision {
                    case .deny:
                        return "ERROR: пользователь отклонил операцию «\(name)»"
                    case .allowSession:
                        await self.addSessionApproval(chatID: chatID, key: key)
                    case .allowOnce:
                        break
                    }
                }
            }

            if name == RagSearchTool.toolName, ragToolDefinition != nil, let ragBridge {
                let outcome = await ragBridge.execute(
                    args,
                    configuration.enabledKnowledgeBaseIDs,
                    configuration.ragTopK,
                    configuration.ragMinScore)
                onRagSources(outcome.sources)
                return outcome.text
            }
            if projectNames.contains(name), let projectBridge {
                return await projectBridge.execute(rootOverride, name, args, fileOps)
            }
            guard let mcpBridge else {
                return "ERROR: исполнитель инструмента «\(name)» недоступен"
            }
            return await mcpBridge.execute(name, args)
        },
        maxIterations: projectNames.isEmpty
            ? ToolUseLoop.defaultMaxIterations : Self.projectToolsMaxIterations,
        fileOps: fileOps,
        projectRoot: projectRoot)
    }
}
