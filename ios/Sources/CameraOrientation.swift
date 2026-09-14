import UIKit

extension UIImage {
    /// カメラが記録した向きを付ける。画素はそのままで、表示のときに回る。
    ///
    /// 横長のまま届いた絵にだけ付ける。すでに誰か（ImageCaptureCore など）が回して縦長になっている絵や、
    /// 向きの付いた絵に重ねて付けると、二重に回ってしまうため
    func applyingCameraOrientation(_ tiff: Int?) -> UIImage {
        guard let tiff, imageOrientation == .up, let cg = cgImage else { return self }
        let orientation: UIImage.Orientation
        switch tiff {
        case 3: orientation = .down
        case 6: orientation = .right       // 表示するには時計回りに 90 度
        case 8: orientation = .left        // 表示するには反時計回りに 90 度
        default: return self
        }
        if tiff != 3 && size.width <= size.height { return self }
        return UIImage(cgImage: cg, scale: scale, orientation: orientation)
    }
}
