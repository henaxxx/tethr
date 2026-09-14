import Foundation
import ImageIO

/// 写真に位置情報を付与する。
///
/// 突き合わせは 2 段構え。
///   1. ファイル名の一致 — iOS 版がテザー中に控えた確定情報。誤差なし。
///   2. 撮影時刻の近傍 — 軌跡から補間。テザーしていない間のカット向け。
///
/// 書き込みは同梱の exiftool に任せる。macOS の ImageIO は RAW を
/// 書き出せず、NEF の MakerNote は内部オフセットを持つため、
/// 自前で構造をいじると原本が壊れる。
struct GeoWriter {

    struct Match {
        let url: URL
        let point: GeoPoint
        /// ファイル名で確定したか、時刻から推定したか
        let exact: Bool
        let captured: Date?
        /// 時刻突き合わせのときの、最も近い軌跡点との差
        let gap: TimeInterval?
    }

    struct Report {
        var written: [String] = []
        var skippedNoMatch: [String] = []
        var failed: [(name: String, reason: String)] = []
        var alreadyTagged: [String] = []
    }

    let payload: GeoPayload
    /// 軌跡から拾うときに許す時刻のずれ
    var tolerance: TimeInterval = 120
    /// すでに位置が入っているファイルを上書きするか
    var overwriteExisting = false

    // MARK: 突き合わせ

    /// 対象フォルダを走査して、付与できるものを洗い出す。
    struct Plan {
        var matches: [Match] = []
        var unmatched: [URL] = []
        /// すでに位置情報を持っているファイル
        var alreadyTagged: [URL] = []
    }

    func plan(in folder: URL) -> Plan {
        let extensions: Set<String> = ["nef", "nrw", "cr2", "cr3", "arw", "raf", "dng", "orf", "rw2", "jpg", "jpeg", "heic", "tif", "tiff"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil))?
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var plan = Plan()

        for url in files {
            // すでに位置がある写真は、上書き指定が無い限り対象から外す
            if !overwriteExisting, Self.hasGPS(url) {
                plan.alreadyTagged.append(url)
                continue
            }
            if let match = match(url) {
                plan.matches.append(match)
            } else {
                plan.unmatched.append(url)
            }
        }
        return plan
    }

    /// 1 枚ぶんの突き合わせ。ファイル名で確定しているものを優先し、無ければ撮影時刻から軌跡上の最寄り点を探す
    func match(_ url: URL) -> Match? {
        let captured = Self.captureDate(of: url)
        if let point = payload.shots[url.lastPathComponent] {
            return Match(url: url, point: point, exact: true, captured: captured, gap: nil)
        }
        if let captured, let (point, gap) = nearestTrackPoint(to: captured), gap <= tolerance {
            return Match(url: url, point: point, exact: false, captured: captured, gap: gap)
        }
        return nil
    }

    /// 取り込む前（カードの上）で、位置を付けられる見込みがあるか。
    /// カードの撮影日時は EXIF と同じカメラの時計なので、同じ規則で判定できる
    func canLocate(name: String, captured: Date?) -> Bool {
        if payload.shots[name] != nil { return true }
        guard let captured, let (_, gap) = nearestTrackPoint(to: captured) else { return false }
        return gap <= tolerance
    }

    private func nearestTrackPoint(to date: Date) -> (GeoPoint, TimeInterval)? {
        var best: (GeoPoint, TimeInterval)?
        for point in payload.track {
            let gap = abs(point.time.timeIntervalSince(date))
            if best == nil || gap < best!.1 { best = (point, gap) }
        }
        return best
    }

    /// EXIF の撮影日時。読むだけなら ImageIO で足りる。
    static func captureDate(of url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: text)
    }

    static func hasGPS(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return props[kCGImagePropertyGPSDictionary] != nil
    }

    // MARK: 書き込み

    /// exiftool を 1 回だけ起動し、引数ファイル経由でまとめて処理する。
    /// 1 ファイルごとに起動すると Perl の立ち上げが毎回入って極端に遅くなる。
    func apply(_ matches: [Match], progress: @escaping (Int, Int) -> Void) -> Report {
        var report = Report()
        guard let tool = ExifTool.locate() else {
            report.failed = matches.map { ($0.url.lastPathComponent, String(localized: "exiftool が見つかりません")) }
            return report
        }

        let targets = matches
        guard !targets.isEmpty else { return report }
        Log.write("位置情報の書き込み開始: \(targets.count) 件")

        // 引数ファイルにまとめる。コマンドラインの長さ制限も避けられる。
        var lines: [String] = []
        for m in targets {
            let p = m.point
            lines.append("-GPSLatitude=\(abs(p.lat))")
            lines.append("-GPSLatitudeRef=\(p.lat >= 0 ? "N" : "S")")
            lines.append("-GPSLongitude=\(abs(p.lon))")
            lines.append("-GPSLongitudeRef=\(p.lon >= 0 ? "E" : "W")")
            if let alt = p.alt {
                lines.append("-GPSAltitude=\(abs(alt))")
                lines.append("-GPSAltitudeRef=\(alt >= 0 ? 0 : 1)")
            }
            lines.append("-overwrite_original")
            lines.append(m.url.path)
            lines.append("-execute")
        }

        let argFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tethr-geo-\(UUID().uuidString).args")
        defer { try? FileManager.default.removeItem(at: argFile) }
        guard (try? lines.joined(separator: "\n").write(to: argFile, atomically: true, encoding: .utf8)) != nil else {
            report.failed = targets.map { ($0.url.lastPathComponent, String(localized: "作業ファイルを作れません")) }
            return report
        }

        let result = tool.run(["-@", argFile.path, "-common_args", "-q"])
        Log.write("exiftool 終了: status \(result.status)"
                  + (result.error.isEmpty ? "" : " / \(result.error.prefix(200))"))
        progress(targets.count, targets.count)

        // 書けたかどうかは実ファイルを読み直して確かめる。
        // exiftool の出力を解釈するより確実。
        for m in targets {
            if Self.hasGPS(m.url) {
                report.written.append(m.url.lastPathComponent)
            } else {
                report.failed.append((m.url.lastPathComponent, result.error.isEmpty ? String(localized: "書き込まれませんでした") : result.error))
            }
        }
        Log.write("書き込み完了: 成功 \(report.written.count) / 失敗 \(report.failed.count)")
        return report
    }
}

/// アプリに同梱した exiftool を起動する。
///
/// exiftool は Perl スクリプトなので、システムの Perl で走らせる。
/// 同梱している都合上、シバンではなく Perl を明示して起動し、
/// モジュールの場所は PERL5LIB で渡す。
struct ExifTool {
    let script: URL
    let libDirectory: URL

    static func locate() -> ExifTool? {
        // 同梱版を最優先。Homebrew の有無に依存しない。
        if let resources = Bundle.main.resourceURL {
            let script = resources.appendingPathComponent("exiftool/exiftool")
            let lib = resources.appendingPathComponent("exiftool/lib")
            if FileManager.default.isReadableFile(atPath: script.path) {
                return ExifTool(script: script, libDirectory: lib)
            }
        }
        // 開発中など、同梱が無い場合の逃げ道
        for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return ExifTool(script: URL(fileURLWithPath: path),
                                libDirectory: URL(fileURLWithPath: "/"))
            }
        }
        return nil
    }

    @discardableResult
    func run(_ arguments: [String]) -> (output: String, error: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env["PERL5LIB"] = libDirectory.path
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return ("", error.localizedDescription, -1)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                process.terminationStatus)
    }

    var version: String? {
        let r = run(["-ver"])
        let v = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
