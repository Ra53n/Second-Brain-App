// ProvidersSettingsTab.swift — вкладка «Провайдеры»: ключи (часть SettingsViews, задача 77).

import SwiftUI

struct ProvidersSettingsTab: View {
    @ObservedObject var registry: ProviderRegistry

    /// Черновики вводимых ключей и результаты проверки — по провайдеру.
    @State private var drafts: [ProviderID: String] = [:]
    @State private var verdicts: [ProviderID: KeyVerifier.Verdict] = [:]
    @State private var verifying: ProviderID?
    /// Тик для перерисовки статуса «ключ задан» после записи в Keychain
    /// (KeyStore — не ObservableObject).
    @State private var keyChangeTick = 0

    var body: some View {
        Form {
            Section {
                ForEach(registry.descriptors.filter(\.requiresKey)) { descriptor in
                    providerRow(descriptor)
                }
            } footer: {
                Text("Ключи хранятся в Keychain и никогда не показываются. Переменная окружения SECONDBRAIN_<ID>_KEY имеет приоритет (для разработки). Локальные провайдеры (Ollama, WhisperKit) ключей не требуют — они на вкладке «Локальные модели».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func providerRow(_ descriptor: ProviderDescriptor) -> some View {
        let hasKey = keyChangeTick >= 0 && KeyStore.hasKey(for: descriptor.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(descriptor.displayName)
                    .fontWeight(.medium)
                Spacer()
                Label(hasKey ? "ключ задан" : "ключа нет",
                      systemImage: hasKey ? "checkmark.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(hasKey ? .green : .secondary)
            }
            HStack {
                SecureField("Новый ключ", text: draftBinding(descriptor.id))
                    .textFieldStyle(.roundedBorder)
                Button("Сохранить") {
                    KeyStore.setKey(drafts[descriptor.id] ?? "", for: descriptor.id)
                    drafts[descriptor.id] = ""
                    verdicts[descriptor.id] = nil
                    keyChangeTick += 1
                }
                .disabled((drafts[descriptor.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button("Удалить", role: .destructive) {
                        KeyStore.setKey("", for: descriptor.id)
                        verdicts[descriptor.id] = nil
                        keyChangeTick += 1
                    }
                    if verifying == descriptor.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Проверить") { verify(descriptor.id) }
                    }
                }
            }
            if let verdict = verdicts[descriptor.id] {
                Label(verdict.label,
                      systemImage: verdict == .ok ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(verdict == .ok ? .green : .orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func draftBinding(_ id: ProviderID) -> Binding<String> {
        Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
    }

    /// Лёгкий запрос к API — принят ли ключ (KeyVerifier).
    private func verify(_ id: ProviderID) {
        guard verifying == nil, let key = KeyStore.key(for: id) else { return }
        verifying = id
        Task {
            let verdict = await KeyVerifier.verify(id: id, key: key)
            verdicts[id] = verdict
            verifying = nil
        }
    }
}
