// Evolis Pebble 4 と USB で直接やり取りする(IOUSBHost)。
// コマンドは ESC + ASCII + CR。返事は NUL 終端で、次のコマンドを送るまで同じ返事が繰り返し読める。
import Foundation
import IOKit
import IOUSBHost

/// 画面の文字列。英語がキーで、日本語の訳は ja.lproj/Localizable.strings にある
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

enum EvolisError: LocalizedError {
    case notFound
    case busy
    case noReply(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return L("Printer not found. Check the USB cable and the power.")
        case .busy:     return L("The printer is busy (printing, etc.). Refresh when it is done.")
        case .noReply(let c): return String(format: L("No reply from the printer (%@)"), c)
        case .io(let s): return String(format: L("Communication failed: %@"), s)
        }
    }
}

final class EvolisPrinter {
    static let vendorID = 0x0F49

    private let interface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe

    init() throws {
        // USB の検索条件は使える組み合わせが決まっていて、メーカー ID + インターフェースの種類 は使えない。
        // インターフェースを全部列挙して、メーカー ID とプリンタクラス(7)で選ぶ
        let service = Self.findPrinterInterface()
        guard service != IO_OBJECT_NULL else { throw EvolisError.notFound }
        defer { IOObjectRelease(service) }

        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch let e as NSError where e.code == Int(kIOReturnExclusiveAccess) {
            throw EvolisError.busy        // CUPS の USB の送信処理が掴んでいる(印刷中)
        } catch {
            throw EvolisError.io(error.localizedDescription)
        }

        // バルクの OUT / IN のエンドポイントを探す
        var outAddr: UInt8 = 0, inAddr: UInt8 = 0
        let config = interface.configurationDescriptor
        let iface = interface.interfaceDescriptor
        var ep = IOUSBGetNextEndpointDescriptor(config, iface, nil)
        while let e = ep {
            let addr = e.pointee.bEndpointAddress
            if e.pointee.bmAttributes & 0x03 == 0x02 {          // bulk
                if addr & 0x80 != 0 { inAddr = addr } else { outAddr = addr }
            }
            ep = IOUSBGetNextEndpointDescriptor(config, iface, UnsafeRawPointer(e).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
        }
        guard outAddr != 0, inAddr != 0 else { interface.destroy(); throw EvolisError.io("no bulk endpoints") }
        do {
            outPipe = try interface.copyPipe(withAddress: Int(outAddr))
            inPipe = try interface.copyPipe(withAddress: Int(inAddr))
        } catch {
            interface.destroy(); throw EvolisError.io(error.localizedDescription)
        }
    }

    deinit { interface.destroy() }

    /// 返事を待っている間のタイムアウト(kIOReturnTimeout / kIOUSBTransactionTimeout / タイムアウトで取り消された kIOReturnAborted)
    private static let timeoutCodes: Set<Int> = [Int(Int32(bitPattern: 0xE000_02D6)), Int(Int32(bitPattern: 0xE000_4051)),
                                                 Int(Int32(bitPattern: 0xE000_02EB))]

    /// プリンタが USB につながっているか(開かずに調べる)
    static func isConnected() -> Bool {
        let s = findPrinterInterface()
        guard s != IO_OBJECT_NULL else { return false }
        IOObjectRelease(s)
        return true
    }

    private static func findPrinterInterface() -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS
        else { return IO_OBJECT_NULL }
        defer { IOObjectRelease(iterator) }
        func number(_ s: io_service_t, _ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        var s = IOIteratorNext(iterator)
        while s != IO_OBJECT_NULL {
            if number(s, "idVendor") == vendorID && number(s, "bInterfaceClass") == 7 { return s }
            IOObjectRelease(s)
            s = IOIteratorNext(iterator)
        }
        return IO_OBJECT_NULL
    }

    /// コマンドを送るだけ(返事は読まない)
    func send(_ command: String) throws {
        let data = NSMutableData(data: Data([0x1B]) + Data(command.utf8) + Data([0x0D]))
        var sent = 0
        do { try outPipe.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: 5) }
        catch { throw EvolisError.io(error.localizedDescription) }
    }

    /// コマンドを送って返事を読む。前の返事が残っていることがあるので、先に別のコマンドの返事で読み捨てる。
    /// 本体が新しい返事を用意する前に読むと Rtp の返事がもう一度返るので、変わるまで読み直す
    func query(_ command: String, timeout: TimeInterval = 4) throws -> String {
        // 読み捨てる返事が遅れて届くことがあるので、同じ返事が 2 回続くまで繰り返す。
        // Rtp そのものを読むときは、別のコマンド(Rfv)で読み捨てる(前の返事を Rtp の返事と取り違えないように)
        let flush = command == "Rtp" ? "Rfv" : "Rtp"
        var stale = try rawQuery(flush, timeout: 2)
        for _ in 0..<5 {
            let again = try rawQuery(flush, timeout: 2)
            if again == stale { break }
            stale = again
        }
        try send(command)
        let deadline = Date().addingTimeInterval(timeout)
        var reply = try read(until: deadline)
        while reply == stale, !stale.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            reply = try read(until: deadline)
        }
        // 待っても前の返事のままなら、返事が無かった(本体が知らないコマンドなど)。前の返事を値として返さない
        if reply == stale && !stale.isEmpty { throw EvolisError.noReply(command) }
        return reply
    }

    private func rawQuery(_ command: String, timeout: TimeInterval) throws -> String {
        try send(command)
        return try read(until: Date().addingTimeInterval(timeout))
    }

    /// NUL までの返事を一つ読む
    private func read(until deadline: Date) throws -> String {
        var buf = Data()
        while !buf.contains(0), Date() < deadline {
            let chunk = NSMutableData(length: 512)!
            var got = 0
            do {
                try inPipe.__sendIORequest(with: chunk, bytesTransferred: &got, completionTimeout: 0.3)
                buf.append(chunk.bytes.assumingMemoryBound(to: UInt8.self), count: got)
            } catch let e as NSError where Self.timeoutCodes.contains(e.code) {
                continue                                         // 返事がまだ無い(タイムアウト)
            } catch {
                throw EvolisError.io(error.localizedDescription)  // 抜かれたなど。待っても返事は来ない
            }
        }
        let text = buf.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
