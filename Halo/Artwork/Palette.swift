import SwiftUI
import UIKit

/// Colors pulled from artwork, for tinting backgrounds the way the Music app does.
struct Palette: Equatable, Sendable {
    var primary: Color
    var secondary: Color
    var isLight: Bool

    static let fallback = Palette(primary: Color(white: 0.12), secondary: Color(white: 0.05), isLight: false)

    /// Darkened for use behind white text.
    var background: Color { primary }
}

enum PaletteExtractor {
    private static let cache = NSCache<NSString, PaletteBox>()

    final class PaletteBox: NSObject {
        let palette: Palette
        init(_ p: Palette) { palette = p }
    }

    static func cached(_ key: String) -> Palette? { cache.object(forKey: key as NSString)?.palette }

    static func palette(for image: UIImage, key: String) -> Palette {
        if let hit = cached(key) { return hit }
        let p = extract(image)
        cache.setObject(PaletteBox(p), forKey: key as NSString)
        return p
    }

    /// Downscale to 24×24, bucket the pixels, and pick the most populous vivid color plus a second one.
    static func extract(_ image: UIImage) -> Palette {
        let side = 24
        guard let cg = image.cgImage else { return .fallback }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .fallback }

        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, n = 0.0, weight = 0.0 }
        var buckets: [Int: Bucket] = [:]
        var lumTotal = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let sat = maxC == 0 ? 0 : (maxC - minC) / maxC
            lumTotal += 0.2126 * r + 0.7152 * g + 0.0722 * b
            let key = (Int(r * 5) * 36) + (Int(g * 5) * 6) + Int(b * 5)
            var bucket = buckets[key] ?? Bucket()
            bucket.r += r; bucket.g += g; bucket.b += b; bucket.n += 1
            // Prefer colorful, mid-bright pixels.
            bucket.weight += 0.35 + sat * 1.4 + (maxC > 0.15 && maxC < 0.95 ? 0.4 : 0)
            buckets[key] = bucket
        }
        let ranked = buckets.values.sorted { $0.weight > $1.weight }
        guard let top = ranked.first else { return .fallback }
        func color(_ b: Bucket) -> (Double, Double, Double) { (b.r / b.n, b.g / b.n, b.b / b.n) }
        let c1 = color(top)
        let c2 = ranked.dropFirst().first(where: { other in
            let c = color(other)
            return abs(c.0 - c1.0) + abs(c.1 - c1.1) + abs(c.2 - c1.2) > 0.35
        }).map(color) ?? (c1.0 * 0.4, c1.1 * 0.4, c1.2 * 0.4)

        let avgLum = lumTotal / Double(side * side)
        return Palette(primary: tame(c1), secondary: tame(c2, darker: true), isLight: avgLum > 0.6)
    }

    /// Keep tints dark enough for white text, like the Music app's backgrounds.
    private static func tame(_ c: (Double, Double, Double), darker: Bool = false) -> Color {
        let ui = UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let brightness = min(b, darker ? 0.32 : 0.48)
        let saturation = min(s * 1.05, 0.85)
        return Color(hue: Double(h), saturation: Double(saturation), brightness: Double(max(brightness, 0.12)))
    }
}
