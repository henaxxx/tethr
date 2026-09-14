import Foundation
import ImageCaptureCore

public enum PTPError: LocalizedError {
    case notConnected
    /// カメラが OK 以外を返した（または送る前にこちらで断った）
    case response(UInt16)
    /// 返事が来ないまま待つのをやめた
    case timedOut(String)

    public var code: UInt16? {
        if case .response(let code) = self { return code }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "カメラが接続されていません")
        case .response(let code): return String(localized: "カメラが応答しました: \(PTP.responseName(code))")
        case .timedOut(let op): return String(localized: "カメラから返事がありません（\(op)）")
        }
    }
}

/// カメラから届くイベント 1 件。CheckEvent の返り値にも、USB のイベントにも使う
public struct PTPEvent: Equatable {
    public let code: UInt16
    public let param: UInt32

    public init(code: UInt16, param: UInt32) {
        self.code = code
        self.param = param
    }

    /// Nikon CheckEvent (0x90C7) の返り値: uint16 個数 → (uint16 イベント, uint32 引数) の並び
    public static func checkEvent(_ data: Data) -> [PTPEvent] {
        var r = PTPReader(data)
        guard let count = r.read(UInt16.self), count < 256 else { return [] }
        var events: [PTPEvent] = []
        for _ in 0..<count {
            guard let code = r.read(UInt16.self), let param = r.read(UInt32.self) else { break }
            events.append(PTPEvent(code: code, param: param))
        }
        return events
    }

    /// ImageCaptureCore が渡す USB のイベント:
    ///   uint32 長さ / uint16 種別 / uint16 コード / uint32 トランザクション / uint32 引数1
    public static func container(_ data: Data) -> PTPEvent? {
        var r = PTPReader(data)
        guard r.read(UInt32.self) != nil, r.read(UInt16.self) != nil, let code = r.read(UInt16.self) else { return nil }
        _ = r.read(UInt32.self)
        return PTPEvent(code: code, param: r.read(UInt32.self) ?? 0)
    }

    public static let objectAdded: UInt16 = 0x4002
    public static let devicePropChanged: UInt16 = 0x4006
    public static let captureComplete: UInt16 = 0x400D
}

/// セッションを開いたカメラ 1 台に、生の PTP 命令を送る。
///
/// ImageCaptureCore は iOS と macOS のどちらでも requestSendPTPCommand で生の命令を通す。
/// ここに置いた手順は、D300 の実機（iOS と Mac）で確かめたもの
@MainActor
public final class PTPCamera {
    public let device: ICCameraDevice
    public private(set) var info: DeviceInfo?
    public private(set) var capabilities: CameraCapabilities?
    /// 返事を待っている命令の数
    public private(set) var inFlight = 0
    public var log: (String) -> Void
    private var refusalsLogged: Set<String> = []

    /// Nikon の露出計（1/6 EV 刻みの符号付き整数）
    public static let lightMeterCode: UInt32 = 0xD1B1
    /// Nikon のバッファ残り（連写であと何コマ撮れるか）
    public static let maximumShotsCode: UInt32 = 0xD103

    public init(device: ICCameraDevice, log: @escaping (String) -> Void = { _ in }) {
        self.device = device
        self.log = log
    }

    public var isNikon: Bool { PropFormat.vendor == PropFormat.vendorNikon }

    // MARK: 命令

    /// 生の PTP 命令を送り、データ段を返す。OK 以外の応答は `PTPError.response` で投げる。
    ///
    /// DeviceInfo を読む前と、Nikon 1 で通信を壊す命令は、送らずに断る（`CameraCapabilities`）
    @discardableResult
    public func send(_ op: PTP.Op, params: [UInt32] = [], outData: Data? = nil,
                     timeout: TimeInterval? = nil) async throws -> Data {
        let refusal = capabilities.map { $0.refusal(op, params: params) }
            ?? CameraCapabilities.refusalBeforeDeviceInfo(op, params: params)
        if let refusal {
            let key = "\(op.rawValue)-\(params.first ?? 0)"
            if !refusalsLogged.contains(key) {
                refusalsLogged.insert(key)
                log(String(format: "送らなかった 0x%04X%@: %@", op.rawValue,
                           params.first.map { String(format: "(0x%X)", $0) } ?? "", refusal.reason))
            }
            throw PTPError.response(refusal.code)
        }
        let label = String(format: "0x%04X", op.rawValue)
        inFlight += 1
        // 待つ上限を決めていない命令が長く返らないときは残す。止まったまま戻らない不具合を追うため
        let started = Date()
        let watchdog: Task<Void, Never>? = timeout == nil ? Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.log("PTP \(label) が 45 秒返らない")
        } : nil
        defer {
            inFlight -= 1
            watchdog?.cancel()
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 45 { log(String(format: "PTP %@ がようやく返った（%.0f 秒）", label, elapsed)) }
        }
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            device.requestSendPTPCommand(PTP.command(op, params: params), outData: outData) { data, response, error in
                guard once.claim() else { return }
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let code = PTP.responseCode(response)
                if code == 0x2001 {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: PTPError.response(code))
                }
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard once.claim() else { return }
                    cont.resume(throwing: PTPError.timedOut(label))
                }
            }
        }
    }

    /// 何を送ってよいかを知る。読めたらメーカーも決まり、独自の値の読み方が切り替わる
    @discardableResult
    public func readDeviceInfo() async -> DeviceInfo? {
        guard let data = try? await send(.getDeviceInfo), let info = DeviceInfo(data) else { return nil }
        self.info = info
        capabilities = CameraCapabilities(info)
        PropFormat.vendor = info.effectiveVendor
        return info
    }

    // MARK: 設定

    public func describe(_ prop: PTP.Prop) async -> PropDesc? {
        guard let data = try? await send(.getDevicePropDesc, params: [UInt32(prop.rawValue)]) else { return nil }
        return PropDesc(data)
    }

    public func describeAll(_ props: [PTP.Prop] = PTP.Prop.allCases) async -> [PTP.Prop: PropDesc] {
        var result: [PTP.Prop: PropDesc] = [:]
        for prop in props {
            if let desc = await describe(prop) { result[prop] = desc }
        }
        return result
    }

    /// 設定を書き換える。データ型に応じた幅で値を詰める
    public func write(_ desc: PropDesc, value: Int64) async throws {
        var payload = Data()
        switch desc.dataType {
        case .int8, .uint8:   payload.appendLE(UInt8(truncatingIfNeeded: value))
        case .int16, .uint16: payload.appendLE(UInt16(truncatingIfNeeded: value))
        case .int32, .uint32: payload.appendLE(UInt32(truncatingIfNeeded: value))
        case .int64, .uint64: payload.appendLE(UInt64(truncatingIfNeeded: value))
        case .string:         throw PTPError.response(0x2006)
        }
        try await send(.setDevicePropValue, params: [UInt32(desc.code.rawValue)], outData: payload)
    }

    /// 値だけを整数で読む。幅は返ってきたバイト数で決める（機種で違う）
    public func integer(_ code: UInt32, signed: Bool = false) async -> Int64? {
        guard let data = try? await send(.getDevicePropValue, params: [code]) else { return nil }
        var r = PTPReader(data)
        switch data.count {
        case 1: return signed ? r.read(Int8.self).map(Int64.init) : r.read(UInt8.self).map(Int64.init)
        case 2: return signed ? r.read(Int16.self).map(Int64.init) : r.read(UInt16.self).map(Int64.init)
        case 4: return signed ? r.read(Int32.self).map(Int64.init) : r.read(UInt32.self).map(Int64.init)
        default: return nil
        }
    }

    /// 露出計（EV）。Nikon は M モードでだけ適正からのずれを示す
    public func lightMeter() async -> Double? {
        await integer(Self.lightMeterCode, signed: true).map { Double($0) / 6 }
    }

    // MARK: 状態

    /// Nikon の作法で、カメラが次の命令を受けられるようになるまで待つ（libgphoto2 の nikon_wait_busy）。
    /// 最後の応答コードを返す。AF のあとなら 0xA002（ピントが合わない）が返ることがある
    @discardableResult
    public func waitUntilReady(seconds: Double) async -> UInt16 {
        guard isNikon else {
            try? await Task.sleep(for: .milliseconds(300))
            return 0x2001
        }
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            do {
                try await send(.nikonDeviceReady)
                return 0x2001
            } catch PTPError.response(let code) where code == 0x2019 || code == 0xA200 {
                // DeviceBusy / Bulb_Release_Busy
                guard Date() < deadline else { return code }
                try? await Task.sleep(for: .milliseconds(100))
            } catch PTPError.response(let code) {
                return code
            } catch {
                return 0
            }
        }
    }

    /// 本体側で変わったもの。Nikon は変化を勝手に送ってこないので、こちらから聞く
    public func checkEvent() async throws -> [PTPEvent] {
        PTPEvent.checkEvent(try await send(.nikonCheckEvent))
    }

    // MARK: 撮影

    /// AF を走らせて、合ったかを返す（シャッター半押しに相当）。命令自体が通らなければ nil
    public func autofocus() async -> Bool? {
        do {
            try await send(.nikonAfDrive)
        } catch {
            // AF-C や MF では合焦通知自体が来ないことがある。撮影は止めない
            log("AF 命令が通らない: \(error.localizedDescription)")
            return nil
        }
        let code = await waitUntilReady(seconds: 5)
        return code != 0xA002
    }

    /// シャッターを切る。撮影ファイルは一覧への追加（ObjectAdded）で届く
    public func releaseShutter() async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await send(.initiateCapture, params: [0, 0])
                log("リモートシャッター 0x100E: OK")
                return
            } catch PTPError.response(0x2019) where attempt < 5 {
                // まだ AF やミラーが動いている。libgphoto2 と同じく、落ち着くのを待って同じ命令を送り直す。
                // ここで別の撮影命令に切り替えると、遅れて両方が効いて何度も切れるおそれがある
                log("リモートシャッター 0x100E: DeviceBusy（待って送り直す）")
                await waitUntilReady(seconds: 2)
            } catch PTPError.response(0x2019) {
                throw PTPError.response(0x2019)
            } catch {
                log("リモートシャッター 0x100E 失敗: \(error.localizedDescription)")
                // 標準命令が通らない機種向けに Nikon 独自命令も試す（Nikon 1 では送らない）
                do {
                    try await send(.nikonCapture, params: [0xFFFFFFFF])
                    log("リモートシャッター 0x90C0: OK")
                    return
                } catch {
                    throw error
                }
            }
        }
    }

    // MARK: 時計

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// カメラの内蔵時計（PTP の DateTime は文字列。機種によって ".0" や "Z" が付くので先頭 15 文字だけ読む）
    public func cameraClock() async -> Date? {
        guard let data = try? await send(.getDevicePropValue, params: [PTP.dateTimeProp]),
              let text = PTP.decodeString(data) else { return nil }
        return Self.clockFormat.date(from: String(text.prefix(15)))
    }

    public func setCameraClock(_ date: Date) async throws {
        try await send(.setDevicePropValue, params: [PTP.dateTimeProp],
                       outData: PTP.encodeString(Self.clockFormat.string(from: date)))
    }
}

/// 完了とタイムアウトのどちらか先に来た方だけを通す
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
