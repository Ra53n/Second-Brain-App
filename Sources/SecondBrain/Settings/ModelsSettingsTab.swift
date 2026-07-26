// ModelsSettingsTab.swift — вкладка «Модели»: роутинг функция → провайдер (часть SettingsViews, задача 77).

import SwiftUI

struct ModelsSettingsTab: View {
    @ObservedObject var router: FunctionRouter
    @ObservedObject var registry: ProviderRegistry

    /// Метка «Авто» в пикере провайдера (нет явного назначения).
    private static let autoTag: ProviderID? = nil

    var body: some View {
        Form {
            Section {
                ForEach(AppFunction.allCases, id: \.rawValue) { function in
                    functionRow(function)
                }
            } footer: {
                Text("«Авто» — первый доступный провайдер нужного типа. Явное назначение действует, пока провайдер доступен; иначе прозрачно работает автодефолт (строка с предупреждением).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func functionRow(_ function: AppFunction) -> some View {
        let issue = RoutingValidator.issues(config: router.config, registry: registry)
            .first { $0.function == function }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(function.displayName, selection: providerBinding(function)) {
                    Text("Авто").tag(Self.autoTag)
                    ForEach(registry.descriptors(supporting: function.requiredCapability)) { descriptor in
                        Text(descriptor.displayName).tag(Optional(descriptor.id))
                    }
                }
                if router.assignment(for: function) != nil {
                    TextField("модель", text: modelBinding(function))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            if let issue {
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    /// Пикер провайдера: nil — «Авто» (снять назначение).
    private func providerBinding(_ function: AppFunction) -> Binding<ProviderID?> {
        Binding(
            get: { router.assignment(for: function)?.providerID },
            set: { newID in
                guard let newID else {
                    router.clearAssignment(for: function)
                    return
                }
                // Модель — прежняя (если менялся только провайдер, обычно
                // нужна свежая), иначе дефолтная провайдера.
                let model = registry.descriptor(for: newID)?
                    .defaultModel(for: function.requiredCapability) ?? ""
                router.assign(FunctionAssignment(providerID: newID, model: model), to: function)
            }
        )
    }

    private func modelBinding(_ function: AppFunction) -> Binding<String> {
        Binding(
            get: { router.assignment(for: function)?.model ?? "" },
            set: { newModel in
                guard var assignment = router.assignment(for: function) else { return }
                assignment.model = newModel
                router.assign(assignment, to: function)
            }
        )
    }
}
