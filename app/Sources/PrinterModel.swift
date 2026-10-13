// プリンタの状態を読み、テストカードやクリーニングを呼ぶ。USB の処理は裏のスレッドで行う
import Foundation

struct StatusRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

@MainActor
final class PrinterModel: ObservableObject {
    @Published var printer: [StatusRow] = []
    @Published var settings: [StatusRow] = []
    @Published var cleaning: [StatusRow] = []
    @Published var needsCleaning = false
    @Published var message: String?
    @Published var working = false

    func refresh() {
        run(label: nil) { p in
            func q(_ c: String) throws -> String { try p.query(c) }
            let printer = [
                StatusRow(label: "機種", value: try q("Rtp")),
                StatusRow(label: "ファームウェア", value: try q("Rfv")),
                StatusRow(label: "入れたカードの数", value: Self.number(try q("Rco;c")) + " 枚"),
                StatusRow(label: "刷ったパネルの数", value: Self.number(try q("Rco;p"))),
            ]
            let ribbon = try q("Rr;p")
            // ドライバの「カラーの明るさ」は、本体の Pl(大きいほど濃い)を逆にしたもの
            let pl = Int(try q("Rl;y")).map { String(20 - $0) } ?? "?"
            let settings = [
                StatusRow(label: "リボンの設定", value: Self.ribbonName(ribbon)),
                StatusRow(label: "黒 / 単色リボンの濃さ", value: try q("Rc;k")),
                StatusRow(label: "カラーの濃さ", value: try q("Rc;y")),
                StatusRow(label: "カラーの明るさ", value: pl),
                StatusRow(label: "オーバーレイの濃さ", value: try q("Rc;o")),
            ]
            let due = try q("Rlr;r")
            let cleaning = [
                StatusRow(label: "クリーニングの時期", value: due == "OK" ? "まだ要りません" : "クリーニングしてください（\(due)）"),
                StatusRow(label: "クリーニングの回数", value: Self.number(try q("Rco;n")) + " 回"),
                StatusRow(label: "クリーニングの平均間隔", value: Self.number(try q("Rco;a")) + " 枚"),
                StatusRow(label: "クリーニングの最大間隔", value: Self.number(try q("Rco;m")) + " 枚"),
            ]
            return { model in
                model.printer = printer
                model.settings = settings
                model.cleaning = cleaning
                model.needsCleaning = due != "OK"
            }
        }
    }

    func testCard()      { send("St", label: "テストカードを刷っています…") }
    func technicalCard() { send("Stt", label: "技術テストカードを刷っています…") }
    func clean()         { send("Scp", label: "クリーニングしています…") }

    /// 本体の機能を呼び、終わる(また返事が来る)まで待ってから状態を読み直す
    private func send(_ command: String, label: String) {
        run(label: label) { p in
            try p.send(command)
            let deadline = Date().addingTimeInterval(180)
            Thread.sleep(forTimeInterval: 5)
            while Date() < deadline {
                if (try? p.query("Rtp", timeout: 2)) == "Pebble 4" { break }
                Thread.sleep(forTimeInterval: 3)
            }
            return { _ in }
        } then: { [weak self] in self?.refresh() }
    }

    private func run(label: String?,
                     _ work: @escaping @Sendable (EvolisPrinter) throws -> (@MainActor (PrinterModel) -> Void),
                     then next: (@MainActor () -> Void)? = nil) {
        guard !working else { return }
        working = true
        message = label
        Task.detached {
            let result: Result<@MainActor (PrinterModel) -> Void, Error>
            do {
                let printer = try EvolisPrinter()
                result = .success(try work(printer))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.working = false
                switch result {
                case .success(let apply): self.message = nil; apply(self); next?()
                case .failure(let e):     self.message = e.localizedDescription
                }
            }
        }
    }

    nonisolated static func number(_ s: String) -> String {
        guard let n = Int(s) else { return s }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? s
    }

    nonisolated static func ribbonName(_ code: String) -> String {
        let names = ["k Black": "黒", "ymcko": "YMCKO カラー（全面パネル）", "ymckos": "YMCKO カラー（ハーフパネル）",
                     "ko": "黒 + オーバーレイ", "k White": "白", "k Red": "赤", "k Blue": "青", "k Green": "緑",
                     "k Gold": "金", "k Silver": "銀", "k Scratch": "スクラッチ", "k Wax Plastic": "黒ワックス"]
        return names[code].map { "\($0)（\(code)）" } ?? code
    }
}
