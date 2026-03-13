import SwiftUI
import UIKit

struct VariableBlurView: UIViewRepresentable {
    var startPoint: CGFloat
    var endPoint: CGFloat
    var style: UIBlurEffect.Style = .systemMaterialDark

    func makeUIView(context: Context) -> VariableBlurUIView {
        VariableBlurUIView(startPoint: startPoint, endPoint: endPoint, style: style)
    }

    func updateUIView(_ uiView: VariableBlurUIView, context: Context) {
        uiView.updatePoints(start: startPoint, end: endPoint)
    }
}

final class VariableBlurUIView: UIView {
    private let blurView: UIVisualEffectView
    private let maskLayer = CAGradientLayer()

    init(startPoint: CGFloat, endPoint: CGFloat, style: UIBlurEffect.Style = .systemMaterialDark) {
        blurView = UIVisualEffectView(effect: UIBlurEffect(style: style))
        super.init(frame: .zero)
        maskLayer.colors = [UIColor.clear.cgColor, UIColor.white.cgColor]
        maskLayer.startPoint = CGPoint(x: 0.5, y: startPoint)
        maskLayer.endPoint = CGPoint(x: 0.5, y: endPoint)
        blurView.layer.mask = maskLayer
        addSubview(blurView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updatePoints(start: CGFloat, end: CGFloat) {
        maskLayer.startPoint = CGPoint(x: 0.5, y: start)
        maskLayer.endPoint = CGPoint(x: 0.5, y: end)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Dominant Color Extraction

extension UIImage {
    /// Samples the bottom 10% strip of the image and returns the average color.
    func averageBottomColor() -> UIColor {
        guard let cgImage else { return UIColor(white: 0.12, alpha: 1) }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return UIColor(white: 0.12, alpha: 1) }

        // Sample bottom 10% strip
        let stripHeight = max(1, h / 10)
        let startY = h - stripHeight
        guard let cropped = cgImage.cropping(to: CGRect(x: 0, y: startY, width: w, height: stripHeight)) else {
            return UIColor(white: 0.12, alpha: 1)
        }

        // Scale down to 1x1 to get average color
        let size = CGSize(width: 1, height: 1)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIColor(white: 0.12, alpha: 1) }
        ctx.interpolationQuality = .medium
        ctx.draw(UIImage(cgImage: cropped).cgImage!, in: CGRect(origin: .zero, size: size))
        guard let data = ctx.makeImage()?.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return UIColor(white: 0.12, alpha: 1) }

        let r = CGFloat(ptr[0]) / 255
        let g = CGFloat(ptr[1]) / 255
        let b = CGFloat(ptr[2]) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
