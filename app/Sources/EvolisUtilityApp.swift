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
    @StateObject private var settings = PrintSettings()
    @State private var confirm: Action?
    @State private var editingHead = false
    @State private var tab = Tab.printer

    enum Tab: Hashable { case printer, printing, cleaning }

    enum Action: Identifiable {
        case test, technical, clean
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
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
                }
                .formStyle(.grouped)
                .tabItem { Text("Printer") }
                .tag(Tab.printer)

                Form {
                    if settings.available {
                        printSettings
                    } else {
                        Text("The Printer Application is not installed, or the printer is not registered. Run: sudo evolis-setup")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .tabItem { Text("Print settings") }
                .tag(Tab.printing)

                Form {
                    Section {
                        rows(model.cleaning)
                    } footer: {
                        Text("Cleaning needs a cleaning card. Remove the ribbon before running it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .tabItem { Text("Cleaning") }
                .tag(Tab.cleaning)
            }
            .padding(.top, 8)

            if let message = model.message {
                HStack(spacing: 8) {
                    if model.working { ProgressView().controlSize(.small) }
                    Text(message).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }

            HStack {
                switch tab {
                case .printer:
                    Button("Test card…") { confirm = .test }
                    Button("Technical test card…") { confirm = .technical }
                case .cleaning:
                    Button("Clean…") { confirm = .clean }
                case .printing:
                    EmptyView()
                }
                Spacer()
                Button("Refresh") { model.refresh(); settings.load() }
                    .keyboardShortcut("r")
            }
            .disabled(model.working)
            .padding(20)
        }
        .onAppear { model.refresh(); settings.load() }
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

    /// macOS から刷るときの設定(Printer Application の既定値)。変えるとすぐ保存される
    private var printSettings: some View {
        Section {
            picker(L("Ribbon"), "evolis-ribbon", "k", PrintSettings.ribbons)
            picker(L("Overlay (protective layer)"), "evolis-overlay", "full", PrintSettings.overlays)
            picker(L("Black panel rendering"), "evolis-black-mode", "gray", PrintSettings.blackModes)
            level(L("Black / monochrome ribbon density"), "evolis-black-density")
            level(L("Color density"), "evolis-color-density")
            level(L("Color brightness"), "evolis-color-brightness")
            level(L("Overlay density"), "evolis-overlay-density")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Used when printing from macOS. Match the ribbon to the one in the printer. Densities: 0–20, standard 10 (brightness: higher is lighter).")
                if let error = settings.error { Text(error).foregroundStyle(.red) }
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func picker(_ title: String, _ attr: String, _ fallback: String, _ choices: [Choice]) -> some View {
        Picker(title, selection: Binding(get: { settings.value(attr, fallback) },
                                         set: { settings.set(attr, $0) })) {
            ForEach(choices) { Text($0.label).tag($0.value) }
        }
    }

    private func level(_ title: String, _ attr: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(settings.number(attr))").monospacedDigit()
                Stepper("", value: Binding(get: { settings.number(attr) }, set: { settings.set(attr, String($0)) }),
                        in: 0...20)
                    .labelsHidden()
            }
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
