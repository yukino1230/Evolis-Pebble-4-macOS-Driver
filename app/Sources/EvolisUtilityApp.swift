// Evolis Pebble 4 のユーティリティ: 状態の表示、テストカード、クリーニング
import SwiftUI

@main
struct EvolisUtilityApp: App {
    var body: some Scene {
        WindowGroup("Evolis Utility") {
            ContentView()
                .frame(minWidth: 460, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var model = PrinterModel()
    @State private var confirm: Action?

    enum Action: Identifiable {
        case test, technical, clean
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                section(L("Printer"), model.printer)
                section(L("Settings stored in the printer"), model.settings)
                Section {
                    rows(model.cleaning)
                } header: {
                    Text("Cleaning")
                } footer: {
                    Text("Cleaning needs a cleaning card. Remove the ribbon before running it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let message = model.message {
                HStack(spacing: 8) {
                    if model.working { ProgressView().controlSize(.small) }
                    Text(message).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }

            HStack {
                Button("Test card…") { confirm = .test }
                Button("Technical test card…") { confirm = .technical }
                Button("Clean…") { confirm = .clean }
                Spacer()
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
            }
            .disabled(model.working)
            .padding(20)
        }
        .onAppear { model.refresh() }
        .confirmationDialog(title(confirm), isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { action in
            Button(button(action)) {
                switch action {
                case .test:      model.testCard()
                case .technical: model.technicalCard()
                case .clean:     model.clean()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(detail(action))
        }
    }

    private func section(_ title: String, _ items: [StatusRow]) -> some View {
        Section(title) { rows(items) }
    }

    @ViewBuilder private func rows(_ items: [StatusRow]) -> some View {
        if items.isEmpty {
            Text("—").foregroundStyle(.secondary)
        }
        ForEach(items) { row in
            LabeledContent(row.label) { Text(row.value).textSelection(.enabled) }
        }
    }

    private func title(_ a: Action?) -> String {
        switch a {
        case .test: return L("Print a test card?")
        case .technical: return L("Print a technical test card?")
        case .clean: return L("Clean the printer?")
        case nil: return ""
        }
    }
    private func button(_ a: Action) -> String {
        switch a { case .test, .technical: return L("Print"); case .clean: return L("Clean") }
    }
    private func detail(_ a: Action) -> String {
        switch a {
        case .test, .technical:
            return L("This uses one card. The card shows the serial number and other details.")
        case .clean:
            return L("Remove the ribbon and put a cleaning card in the feeder before running it.")
        }
    }
}
