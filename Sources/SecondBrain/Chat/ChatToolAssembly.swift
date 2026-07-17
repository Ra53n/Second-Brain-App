// ChatToolAssembly.swift — единая точка сборки инструментов хода (задача 36).
//
// До неё логика «MCP-серверы чата + инструменты проекта + rag_search и
// маршрутизация вызовов между мостами» дублировалась в startGeneration
// (одиночный ход) и runAgentPhase (фаза FSM 35). Теперь оба пути и движок
// пайплайнов собирают инструменты здесь; порядок неизменен: MCP → проект →
// rag_search последним (маршрутизация проверяет его первым, имена не
// пересекаются — MCP-имена всегда содержат «__»).

import Foundation

extension ChatViewModel {
    /// Инструменты хода + единый маршрутизирующий исполнитель.
    struct AssembledTooling {
        var tools: [ToolDefinition]
        var execute: (String, String) async -> String
    }

    /// Сборка по конфигурации чата. forceProjectTools — переопределение хода
    /// (/help включает инструменты проекта независимо от настройки чата).
    /// onRagSources — накопление источников rag_search: одиночный ход цепляет
    /// их к сообщению-заглушке прямо в ходе цикла, FSM копит в исход фазы.
    func assembleTooling(configuration: ChatConfiguration,
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
        if configuration.projectToolsEnabled || forceProjectTools,
           let project = projectToolsBridge {
            let projectTools = project.tools()
            projectNames = Set(projectTools.map(\.name))
            tools += projectTools
        }
        if let ragToolDefinition { tools.append(ragToolDefinition) }

        let mcpBridge = self.mcpBridge
        let projectBridge = self.projectToolsBridge
        let ragBridge = self.ragToolBridge
        return AssembledTooling(tools: tools, execute: { name, args in
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
                return await projectBridge.execute(name, args)
            }
            guard let mcpBridge else {
                return "ERROR: исполнитель инструмента «\(name)» недоступен"
            }
            return await mcpBridge.execute(name, args)
        })
    }
}
