// 標準入力のバイト列を、USB でつないだ Evolis のプリンタにそのまま送る。
// CUPS を通さずに印刷するとき(ipp/evolis-ipp-print、PPD が使えなくなったとき用)に使う。
//   rastertoevolis ... | evolis-usb-send
// USB の処理は Evolis Utility と同じもの(app/Sources/EvolisUSB.swift)
import Foundation

@main
struct EvolisUSBSend {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
        exit(1)
    }

    static func main() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { fail("Nothing to send") }
        // CUPS が前のジョブを送っている間などは使用中になるので、少し待ってやり直す
        for _ in 0..<30 {
            do {
                let printer = try EvolisPrinter()
                try printer.write(data)
                FileHandle.standardError.write(Data("INFO: Sent \(data.count) bytes\n".utf8))
                exit(0)
            } catch EvolisError.busy {
                sleep(2)
            } catch {
                fail(error.localizedDescription)
            }
        }
        fail(EvolisError.busy.localizedDescription)
    }
}
