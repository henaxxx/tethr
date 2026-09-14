import Foundation
import IOKit

/// USB に PTP のカメラ（静止画クラスのインターフェース）が挿さっているかを見張る。
///
/// 電源を入れてから ImageCaptureCore がカメラを知らせてくるまで、D300 では 44 秒かかった
/// （その間 macOS がカードを下調べしている）。そのあいだ「カメラが見つかりません」と出していたので、
/// つながっていないと誤解された。USB に現れた時点で分かれば「準備中」と出せる
@MainActor
final class USBCameraWatcher {

    struct Camera: Equatable {
        let name: String
        /// USB に現れた時刻
        let since: Date
    }

    /// 挿さっているカメラのうち、最初に現れたもの
    var camera: Camera? { cameras.values.min { $0.since < $1.since } }
    var onChange: (() -> Void)?

    private var cameras: [UInt64: Camera] = [:]
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()

        for (type, callback) in [(kIOFirstMatchNotification, Self.added), (kIOTerminatedNotification, Self.removed)] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, Self.matching(), callback, context, &iterator)
            guard result == KERN_SUCCESS else {
                Log.write("USB の見張りを始められない: \(result)")
                continue
            }
            iterators.append(iterator)
            // 取り出しきると通知が有効になる。起動時に挿さっているカメラもここで拾う
            callback(context, iterator)
        }
    }

    /// PTP（静止画クラス 6、サブクラス 1）のインターフェース
    private static func matching() -> CFDictionary {
        let dict = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        dict["IOPropertyMatch"] = ["bInterfaceClass": 6, "bInterfaceSubClass": 1]
        return dict
    }

    private static let added: IOServiceMatchingCallback = { context, iterator in
        guard let context else { return }
        let watcher = Unmanaged<USBCameraWatcher>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { watcher.drain(iterator, adding: true) }
    }

    private static let removed: IOServiceMatchingCallback = { context, iterator in
        guard let context else { return }
        let watcher = Unmanaged<USBCameraWatcher>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { watcher.drain(iterator, adding: false) }
    }

    private func drain(_ iterator: io_iterator_t, adding: Bool) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            if adding {
                let camera = Self.describe(service)
                cameras[id] = camera
                let ago = -camera.since.timeIntervalSinceNow
                Log.write(ago > 2
                          ? String(format: "USB にカメラ: %@（%.0f 秒前から）", camera.name, ago)
                          : "USB にカメラ: \(camera.name)")
            } else if let camera = cameras.removeValue(forKey: id) {
                Log.write("USB からカメラが外れた: \(camera.name)")
            }
            changed = true
        }
        if changed { onChange?() }
    }

    /// 親の USB デバイスから名前と、挿さった時刻を読む
    private static func describe(_ interface: io_service_t) -> Camera {
        var parent: io_registry_entry_t = 0
        var name = String(localized: "カメラ")
        var since = Date()
        if IORegistryEntryGetParentEntry(interface, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            if let product = IORegistryEntryCreateCFProperty(parent, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                // Nikon は「NIKON DSC D300」と名乗る。ImageCaptureCore の表示（D300）に揃える
                name = product.replacingOccurrences(of: "NIKON DSC ", with: "")
            }
            // sessionID は USB に現れたときの mach_absolute_time。アプリより先に挿さっていたぶんも数えられる
            if let session = IORegistryEntryCreateCFProperty(parent, "sessionID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                let now = mach_absolute_time()
                let attached = session.uint64Value
                if attached <= now {
                    var timebase = mach_timebase_info_data_t()
                    mach_timebase_info(&timebase)
                    let seconds = Double(now - attached) * Double(timebase.numer) / Double(timebase.denom) / 1e9
                    if seconds < 3600 { since = Date(timeIntervalSinceNow: -seconds) }
                }
            }
        }
        return Camera(name: name, since: since)
    }
}
