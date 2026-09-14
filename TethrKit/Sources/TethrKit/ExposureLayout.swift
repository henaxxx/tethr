import Foundation

/// 撮影モードに応じて、利用者が決める露出の値（スクラバーで出す）と、カメラ任せの値（数字だけ出す）を分ける。
/// iOS 版と Mac 版で同じ並びにする
public enum ExposureLayout {

    /// シャッタースピードの設定。Nikon は正確な分数の独自プロパティを使う
    public static func shutter(in props: [PTP.Prop: PropDesc]) -> PTP.Prop {
        (props[.nikonExposureTime]?.choices.isEmpty == false) ? .nikonExposureTime : .exposureTime
    }

    /// スクラバーで操作する設定。撮影モードで、利用者が決める値だけを並べる。
    ///
    /// 以前は常にシャッター・絞り・ISO の 3 本で、A モードではシャッターが押せないまま場所を取り、
    /// A・S・P で一番触る露出補正は表示だけだった
    public static func adjustable(in props: [PTP.Prop: PropDesc]) -> [PTP.Prop] {
        let shutter = shutter(in: props)
        let candidates: [PTP.Prop]
        switch props[.exposureProgram]?.current {          // PTP の ExposureProgramMode
        case 1: candidates = [shutter, .fNumber, .iso]              // M
        case 2: candidates = [.iso, .exposureBias]                  // P
        case 3: candidates = [.fNumber, .iso, .exposureBias]        // A
        case 4: candidates = [shutter, .iso, .exposureBias]         // S
        default:
            // シーンモードなど。カメラが書き換えを許しているものだけ出す
            candidates = [shutter, .fNumber, .iso, .exposureBias].filter { props[$0]?.writable == true }
        }
        return candidates.filter { props[$0]?.choices.isEmpty == false }
    }

    /// カメラ任せになっている露出の値（A モードのシャッターなど）
    public static func cameraDecided(in props: [PTP.Prop: PropDesc]) -> [PTP.Prop] {
        let shutter = shutter(in: props)
        switch props[.exposureProgram]?.current {
        case 2: return [shutter, .fNumber].filter { props[$0] != nil }
        case 3: return [shutter].filter { props[$0] != nil }
        case 4: return [.fNumber].filter { props[$0] != nil }
        default: return []
        }
    }

    /// Nikon の露出インジケータが「適正からのずれ」を示すのは M モードだけ。
    /// P・A・S ではカメラが露出を合わせにいくので振れない（D300 で確認）
    public static func meterMeaningful(in props: [PTP.Prop: PropDesc]) -> Bool {
        props[.exposureProgram]?.current == 1
    }
}
