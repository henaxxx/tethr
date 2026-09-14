#if DEBUG
import Foundation

/// カメラ無しで画面を確かめるための、D300 らしい設定。iOS と Mac のデモ（起動引数 -demo）で共通。
/// 製品版には含めない
public enum DemoCamera {

    /// デモを始めるときの値。mode は撮影モード（1 = M, 2 = P, 3 = A, 4 = S）
    public static func startValues(mode: Int64) -> [PTP.Prop: Int64] {
        [
            .exposureProgram: mode,
            .nikonExposureTime: shutter(numerator: 1, denominator: 15),
            .fNumber: 450, .iso: 400, .exposureBias: -333, .whiteBalance: 6, .batteryLevel: 60,
        ]
    }

    /// 起動引数 -demoMode=M のような指定を撮影モードの値にする。無ければ A
    public static func mode(named name: Substring?) -> Int64 {
        switch name {
        case "M": return 1
        case "P": return 2
        case "S": return 4
        default: return 3
        }
    }

    /// 撮影モードに応じて、カメラ任せの値と露出計を D300 らしく動かす。
    /// - Parameter bodyInfo: 画質・フォーカスモード・焦点距離も足す（Mac の右パネル用）
    public static func apply(_ input: [PTP.Prop: Int64], bodyInfo: Bool = false)
        -> (props: [PTP.Prop: PropDesc], lightMeter: Double?) {
        var v = input
        let mode = v[.exposureProgram] ?? 3
        let apertureChoices: [Int64] = [350, 400, 450, 500, 560, 630, 710, 800, 900, 1000, 1100, 1300, 1400, 1600, 1800, 2000, 2200]

        func seconds(_ raw: Int64) -> Double { Double(raw >> 16) / Double(raw & 0xFFFF) }
        func cameraEV(_ shutter: Int64, _ aperture: Int64) -> Double {
            let n = Double(aperture) / 100
            return log2(n * n / seconds(shutter))
        }
        // 室内の明るさ。ISO と露出補正を織り込んだ、適正になるカメラ側の EV
        let target = 6.3 + log2(Double(v[.iso] ?? 400) / 100) - Double(v[.exposureBias] ?? 0) / 1000
        func nearest(_ choices: [Int64], _ ev: (Int64) -> Double) -> Int64 {
            choices.min { abs(ev($0) - target) < abs(ev($1) - target) } ?? choices[0]
        }
        switch mode {
        case 2:
            v[.fNumber] = 560
            v[.nikonExposureTime] = nearest(shutterChoices) { cameraEV($0, 560) }
        case 3:
            v[.nikonExposureTime] = nearest(shutterChoices) { cameraEV($0, v[.fNumber] ?? 450) }
        case 4:
            v[.fNumber] = nearest(apertureChoices) { cameraEV(v[.nikonExposureTime] ?? 0x1000F, $0) }
        default:
            break
        }
        let shutter = v[.nikonExposureTime] ?? 0x1000F
        let aperture = v[.fNumber] ?? 450
        let deviation = target - cameraEV(shutter, aperture)
        let lightMeter = mode == 1 ? max(-3, min(3, (deviation * 6).rounded() / 6)) : nil

        func desc(_ prop: PTP.Prop, _ type: PTP.DataType, _ choices: [Int64], writable: Bool = true) -> PropDesc {
            PropDesc(code: prop, dataType: type, writable: writable, current: v[prop] ?? choices.first ?? 0, choices: choices)
        }
        var props: [PTP.Prop: PropDesc] = [
            .exposureProgram: desc(.exposureProgram, .uint16, [1, 2, 3, 4]),
            .nikonExposureTime: desc(.nikonExposureTime, .uint32, shutterChoices, writable: mode == 1 || mode == 4),
            .fNumber: desc(.fNumber, .uint16, apertureChoices, writable: mode == 1 || mode == 3),
            .iso: desc(.iso, .uint16, [200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200]),
            .exposureBias: desc(.exposureBias, .int16, (-15...15).map { Int64((Double($0) * 1000 / 3).rounded()) }),
            .whiteBalance: desc(.whiteBalance, .uint16, [2, 4, 5, 6, 7, 0x8010, 0x8011, 0x8012, 0x8013]),
            .batteryLevel: desc(.batteryLevel, .uint8, [], writable: false),
        ]
        if bodyInfo {
            v[.compressionSetting] = v[.compressionSetting] ?? 4
            v[.focusMode] = 0x8011
            v[.focalLength] = 3500
            props[.compressionSetting] = desc(.compressionSetting, .uint8, Array(0...7))
            props[.focusMode] = desc(.focusMode, .uint16, [], writable: false)
            props[.focalLength] = desc(.focalLength, .uint32, [], writable: false)
        }
        return (props, lightMeter)
    }

    public static func shutter(numerator: Int64, denominator: Int64) -> Int64 {
        numerator << 16 | denominator
    }

    /// D300 の 1/3 段の並び。Nikon 独自の分数（上位が分子、下位が分母）
    public static let shutterChoices: [Int64] = {
        let fast: [Int64] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320,
                             250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3]
        let slow: [(Int64, Int64)] = [(10, 25), (1, 2), (10, 16), (10, 13), (1, 1), (13, 10), (16, 10), (2, 1),
                                      (25, 10), (3, 1), (4, 1), (5, 1), (6, 1), (8, 1), (10, 1), (13, 1), (15, 1),
                                      (20, 1), (25, 1), (30, 1)]
        return fast.map { shutter(numerator: 1, denominator: $0) } + slow.map { shutter(numerator: $0.0, denominator: $0.1) }
    }()
}
#endif
