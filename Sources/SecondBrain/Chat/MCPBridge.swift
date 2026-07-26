// MCPBridge.swift — мост ChatViewModel к MCP-инструментам (задача 15, вынесено в 76).

import Foundation

extension ChatViewModel {
    /// MCP-мост (задача 15): инструменты включённых серверов чата и исполнитель.
    struct MCPBridge {
        var tools: (Set<UUID>) async -> [ToolDefinition]
        var execute: (String, String) async -> String
    }
}
