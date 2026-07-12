// ChatViews.swift — UI раздела «Чат» (задача 12): список чатов в средней
// колонке, диалог в detail (лента с markdown-рендером, стриминг, поле ввода,
// пикер модели в тулбаре, отмена генерации, баннер ошибки).

import MarkdownUI
import SwiftUI

// MARK: - Список чатов (средняя колонка)

struct ChatListPane: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedChatID) {
                if viewModel.chats.isEmpty {
                    Text("Чатов пока нет. Нажмите «+».")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.chats) { chat in
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(.secondary)
                        Text(chat.title)
                            .lineLimit(1)
                        Spacer()
                        if chat.isLoading {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .tag(chat.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteChat(chat.id)
                        } label: {
                            Label("Удалить чат", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.newChat()
                } label: {
                    Label("Новый чат", systemImage: "square.and.pencil")
                }
            }
        }
    }
}

// MARK: - Диалог (detail)

struct ChatDetailView: View {
    @ObservedObject var viewModel: ChatViewModel

    private var chat: Chat? { viewModel.selectedChat }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            errorBar
            inputBar
        }
        .navigationTitle(chat?.title ?? "Чат")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { modelPicker }
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let chat, chat.messages.isEmpty {
                        Text("Напишите сообщение, чтобы начать диалог.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(chat?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            // Автопрокрутка к последнему сообщению (стриминг дописывает вниз).
            .onChange(of: chat?.messages.last?.content) {
                if let lastID = chat?.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var errorBar: some View {
        if let error = chat?.errorText {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Сообщение… (⌘⏎ — отправить)",
                      text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .onSubmit { if viewModel.canSend { viewModel.send() } }

            if chat?.isLoading == true {
                Button {
                    if let id = chat?.id { viewModel.cancelGeneration(chatID: id) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Остановить генерацию")
            } else {
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
    }

    /// Пикер модели: провайдеры с capability .chat (локальные помечены);
    /// «Авто» — вернуться к выбору роутера.
    private var modelPicker: some View {
        Menu {
            Button {
                viewModel.setModel(providerID: nil, model: nil)
            } label: {
                if chat?.configuration.providerID == nil {
                    Label("Авто (роутер)", systemImage: "checkmark")
                } else {
                    Text("Авто (роутер)")
                }
            }
            Divider()
            ForEach(viewModel.chatProviderOptions) { descriptor in
                Button {
                    viewModel.setModel(providerID: descriptor.id, model: descriptor.defaultModel)
                } label: {
                    let name = descriptor.isLocal
                        ? "\(descriptor.displayName) — локально"
                        : descriptor.displayName
                    let title = descriptor.defaultModel.map { "\(name) · \($0)" } ?? name
                    if chat?.configuration.providerID == descriptor.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                .disabled(!viewModel.registry.isAvailable(descriptor.id))
            }
        } label: {
            Label(currentModelTitle, systemImage: "cpu")
        }
        .help("Модель для этого чата")
    }

    private var currentModelTitle: String {
        guard let chat else { return "Модель" }
        if let providerID = chat.configuration.providerID {
            let name = viewModel.registry.descriptor(for: providerID)?.displayName
                ?? providerID.rawValue
            return chat.configuration.model.map { "\(name) · \($0)" } ?? name
        }
        return "Авто"
    }
}

/// Пузырь одного сообщения: markdown-рендер, метрики под ответом.
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "Вы" : "Ассистент")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Markdown(message.content.isEmpty ? "…" : message.content)
                .markdownTheme(.docC)
                .textSelection(.enabled)
            if let metrics = message.metrics {
                Text(metricsLine(metrics))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(message.role == .user
                      ? Color.accentColor.opacity(0.08)
                      : Color.secondary.opacity(0.06))
        )
    }

    private func metricsLine(_ metrics: MessageMetrics) -> String {
        var parts = [String(format: "%.1f c", metrics.duration)]
        if let total = metrics.totalTokens { parts.append("\(total) ток.") }
        return parts.joined(separator: " · ")
    }
}
