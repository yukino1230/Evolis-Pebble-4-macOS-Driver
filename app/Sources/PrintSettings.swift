// macOS から刷るときの設定(リボン、オーバーレイ、濃さ)。Printer Application(evolis-printer-app)の
// プリンタの既定値として覚えさせる。読むのは `options`、変えるのは `modify`(どちらも sudo は要らない)
import Foundation

struct Choice: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

@MainActor
final class PrintSettings: ObservableObject {
    nonisolated static let tool = "/usr/local/libexec/evolis/evolis-printer-app"
    nonisolated static let printer = "Evolis Pebble 4"

    // 値と表示名は PPD と同じ(driver/mkppd.py)
    static let ribbons = [
        Choice(value: "k", label: L("Black (monochrome)")),
        Choice(value: "ymcko", label: L("YMCKO color (full panel)")),
        Choice(value: "ymckos", label: L("YMCKO color (half panel, e.g. R3013)")),
        Choice(value: "ko", label: L("Black + overlay (KO)")),
        Choice(value: "kw", label: L("White (monochrome)")),
        Choice(value: "kr", label: L("Red (monochrome)")),
        Choice(value: "kbl", label: L("Blue (monochrome)")),
        Choice(value: "kgr", label: L("Green (monochrome)")),
        Choice(value: "kgo", label: L("Gold (monochrome)")),
        Choice(value: "ksi", label: L("Silver (monochrome)")),
        Choice(value: "ksc", label: L("Scratch-off (monochrome)")),
        Choice(value: "ka", label: L("Black wax (monochrome)")),
    ]
    static let overlays = [
        Choice(value: "full", label: L("Full card")),
        Choice(value: "none", label: L("None")),
        Choice(value: "chipiso", label: L("Avoid IC chip (ISO 7816)")),
        Choice(value: "magstripe", label: L("Avoid magnetic stripe (ISO 7811, back side)")),
    ]
    static let blackModes = [
        Choice(value: "gray", label: L("Gray (halftone)")),
        Choice(value: "line", label: L("Line art (black or white)")),
    ]

    /// Printer Application が入っていて、プリンタが登録されているか
    @Published var available = false
    @Published var values: [String: String] = [:]
    @Published var error: String?

    func value(_ attr: String, _ fallback: String) -> String { values[attr] ?? fallback }
    func number(_ attr: String) -> Int { Int(values[attr] ?? "") ?? 10 }

    func load() {
        guard FileManager.default.isExecutableFile(atPath: Self.tool) else { available = false; return }
        Task.detached {
            let result = Self.run(["options", "-d", Self.printer])
            var found: [String: String] = [:]
            // 既定値の行だけ後ろに括弧が付く("  -o evolis-ribbon=ymckos (default)")。
            // 括弧の中は macOS の言語設定で変わる(「デフォルト」など)ので、括弧があるかだけを見る
            for line in result.output.split(separator: "\n") where line.hasSuffix(")") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard parts.count >= 2, parts[0] == "-o", parts[1].hasPrefix("evolis-") else { continue }
                let kv = parts[1].split(separator: "=", maxSplits: 1)
                if kv.count == 2 { found[String(kv[0])] = String(kv[1]) }
            }
            let values = found
            await MainActor.run {
                self.available = result.status == 0 && !values.isEmpty
                self.values = values
            }
        }
    }

    func set(_ attr: String, _ value: String) {
        guard values[attr] != value else { return }
        values[attr] = value
        Task.detached {
            let result = Self.run(["modify", "-d", Self.printer, "-o", "\(attr)=\(value)"])
            await MainActor.run {
                self.error = result.status == 0 ? nil
                    : String(format: L("Could not save the setting: %@"), result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                if result.status != 0 { self.load() }
            }
        }
    }

    /// evolis-printer-app を動かして、出力と終了コードを返す
    nonisolated static func run(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
