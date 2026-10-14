// Evolis Pebble 4 のユーティリティ: 状態の表示、テストカード、クリーニング
import AppKit
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
    @State private var editingHead = false

    enum Action: Identifiable {
        case test, technical, clean
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L("Printer")) {
                    rows(model.printer)
                    if !model.printer.isEmpty {
                        LabeledContent(L("Print head kit number")) {
                            HStack {
                                Text(model.headKit).textSelection(.enabled)
                                Button("Change…") { editingHead = true }
                                    .disabled(model.working)
                            }
                        }
                    }
                }
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
                // リボンや濃さは Printer Application(evolis-printer-app)の設定画面で決める
                Button("Print settings…") {
                    NSWorkspace.shared.open(URL(string: "http://localhost:8630/Evolis_Pebble_4/printing")!)
                }
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
            }
            .disabled(model.working)
            .padding(20)
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $editingHead) {
            HeadKitView(current: model.headKit) { model.setHeadKit($0) }
        }
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

/// ヘッドを交換したあとに、新しいヘッドのキット番号を入れる画面。
/// 番号を間違えると印刷がおかしくなるので、2 回入れてもらう
struct HeadKitView: View {
    let current: String
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kit = ""
    @State private var again = ""

    private func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).uppercased()
    }
    private var ready: Bool {
        let k = normalized(kit)
        return PrinterModel.isValidKit(k) && k == normalized(again) && k != current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Print head kit number").font(.headline)
            Text("Only after replacing the print head. Enter the kit number on the white label of the new head (for example 179-004-00048).")
                .fixedSize(horizontal: false, vertical: true)
            Text("A wrong number makes the printer print incorrectly and may void the warranty. Clean the printer before printing.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent(L("Current")) { Text(current).textSelection(.enabled) }
                TextField(L("New kit number"), text: $kit)
                TextField(L("Enter it again"), text: $again)
            }
            .font(.body.monospaced())
            if !kit.isEmpty && !PrinterModel.isValidKit(normalized(kit)) {
                Text("A kit number starts with three digits.")
                    .font(.callout).foregroundStyle(.red)
            } else if !again.isEmpty && normalized(kit) != normalized(again) {
                Text("The two numbers do not match.")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { apply(normalized(kit)); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
