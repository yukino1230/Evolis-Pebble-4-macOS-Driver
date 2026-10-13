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
    @Published var headKit = ""
    @Published var message: String?
    @Published var working = false

    func refresh() {
        run(label: nil) { p in
            func q(_ c: String) throws -> String { try p.query(c) }
            let printer = [
                StatusRow(label: L("Model"), value: try q("Rtp")),
                StatusRow(label: L("Firmware"), value: try q("Rfv")),
                StatusRow(label: L("Cards inserted"), value: String(format: L("%@ cards"), Self.number(try q("Rco;c")))),
                StatusRow(label: L("Panels printed"), value: Self.number(try q("Rco;p"))),
            ]
            let kit = try q("Rkn")
            let ribbon = try q("Rr;p")
            // ドライバの「カラーの明るさ」は、本体の Pl(大きいほど濃い)を逆にしたもの
            let pl = Int(try q("Rl;y")).map { String(20 - $0) } ?? "?"
            let settings = [
                StatusRow(label: L("Ribbon setting"), value: Self.ribbonName(ribbon)),
                StatusRow(label: L("Black / monochrome ribbon density"), value: try q("Rc;k")),
                StatusRow(label: L("Color density"), value: try q("Rc;y")),
                StatusRow(label: L("Color brightness"), value: pl),
                StatusRow(label: L("Overlay density"), value: try q("Rc;o")),
            ]
            let due = try q("Rlr;r")
            let cleaning = [
                StatusRow(label: L("Cleaning due"), value: due == "OK" ? L("Not yet") : String(format: L("Clean the printer (%@)"), due)),
                StatusRow(label: L("Cleanings"), value: String(format: L("%@ times"), Self.number(try q("Rco;n")))),
                StatusRow(label: L("Average cleaning interval"), value: String(format: L("%@ cards"), Self.number(try q("Rco;a")))),
                StatusRow(label: L("Maximum cleaning interval"), value: String(format: L("%@ cards"), Self.number(try q("Rco;m")))),
            ]
            return { model in
                model.printer = printer
                model.headKit = kit
                model.settings = settings
                model.cleaning = cleaning
                model.needsCleaning = due != "OK"
            }
        }
    }

    func testCard()      { send("St", label: L("Printing a test card…")) }
    func technicalCard() { send("Stt", label: L("Printing a technical test card…")) }
    func clean()         { send("Scp", label: L("Cleaning…")) }

    /// ヘッドを交換したあと、新しいヘッドのラベルにあるキット番号を本体に書く(Pkn)。
    /// 本体は番号の頭 3 桁(抵抗値 x 10)を印刷の制御に使う
    func setHeadKit(_ kit: String) {
        run(label: L("Setting the print head kit number…")) { p in
            let reply = try p.query("Pkn;\(kit)")
            let now = try p.query("Rkn")
            guard now == kit else {
                throw EvolisError.io(String(format: L("The printer did not accept the kit number (reply: %@)"), reply))
            }
            return { model in model.headKit = now }
        } then: { [weak self] in
            self?.refresh()
        }
    }

    /// キット番号として送ってよい形か。ユーザーガイドの例は 179-004-00048。本体は「抵抗値-ヘッドの番号-版」の形で返す
    nonisolated static func isValidKit(_ kit: String) -> Bool {
        kit.range(of: #"^[0-9]{3}[-0-9A-Z]{3,29}$"#, options: .regularExpression) != nil
    }

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
        // 1510 では Pr;k;t のあと "k" とだけ返ることがある
        let names = ["k Black": L("Black"), "k": L("Black"), "ymcko": L("YMCKO color (full panel)"),
                     "ymckos": L("YMCKO color (half panel)"), "ko": L("Black + overlay"), "k White": L("White"),
                     "k Red": L("Red"), "k Blue": L("Blue"), "k Green": L("Green"), "k Gold": L("Gold"),
                     "k Silver": L("Silver"), "k Scratch": L("Scratch-off"), "k Wax Plastic": L("Black wax")]
        return names[code].map { "\($0) (\(code))" } ?? code
    }
}
