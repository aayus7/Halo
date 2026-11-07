import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders the player's colour backdrop from the cover: small, heavily blurred, a little more saturated.
/// Done once per song off the main thread, so the player itself just draws a static image.
enum Backdrop {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func make(from image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let side: CGFloat = 160
        let input = CIImage(cgImage: cg)
        let scale = side / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = small.clampedToExtent()
        blur.radius = 18

        let color = CIFilter.colorControls()
        color.inputImage = blur.outputImage
        color.saturation = 1.45
        color.brightness = -0.04
        color.contrast = 1.05

        guard let output = color.outputImage?.cropped(to: extent),
              let rendered = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
