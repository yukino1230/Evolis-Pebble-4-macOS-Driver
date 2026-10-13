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
                section("プリンタ", model.printer)
                section("設定（本体に残っている値）", model.settings)
                Section {
                    rows(model.cleaning)
                } header: {
                    Text("クリーニング")
                } footer: {
                    Text("クリーニングにはクリーニングカードが要ります。リボンを外してから実行してください。")
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
                Button("テストカード…") { confirm = .test }
                Button("技術テストカード…") { confirm = .technical }
                Button("クリーニング…") { confirm = .clean }
                Spacer()
                Button("更新") { model.refresh() }
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
            Button("キャンセル", role: .cancel) {}
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
        case .test: return "テストカードを刷りますか？"
        case .technical: return "技術テストカードを刷りますか？"
        case .clean: return "クリーニングしますか？"
        case nil: return ""
        }
    }
    private func button(_ a: Action) -> String {
        switch a { case .test, .technical: return "刷る"; case .clean: return "クリーニングする" }
    }
    private func detail(_ a: Action) -> String {
        switch a {
        case .test, .technical:
            return "カードを 1 枚使います。カードにはシリアル番号などが刷られます。"
        case .clean:
            return "リボンを外し、クリーニングカードをフィーダーに入れてから実行してください。"
        }
    }
}
