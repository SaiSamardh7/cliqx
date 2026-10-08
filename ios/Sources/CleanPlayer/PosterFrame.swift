import CoreGraphics

/// Whether a captured frame has a picture in it.
///
/// `WKWebView.takeSnapshot` does not capture the video layer. A staged video
/// therefore snapshots as a solid black rectangle — so does a DRM-protected
/// frame, and so does a page that has not painted yet. Saved anyway, that image
/// is perfectly valid and very much not nil, so the card's monogram fallback
/// never ran: the library filled with blank black tiles that look like a layout
/// bug rather than a missing poster.
///
/// The test is flatness, not darkness. A real frame of a night scene is dark
/// and still varies; a failed capture is one colour from corner to corner, and
/// a solid white or grey one is no more use as a poster than a black one.
public enum PosterFrame {
    /// Sampled at 8×8. Enough to tell a picture from a flat fill, small
    /// enough to run wherever the snapshot lands. The frame is averaged down
    /// rather than point-sampled, so a repeating pattern cannot alias against
    /// the sample grid and read as flat.
    static let sampleSide = 8

    /// How far apart the lightest and darkest samples must be, out of 255, for
    /// this to count as a picture. Low on purpose: the question is whether
    /// ANYTHING varies, and a frame with real content clears it easily.
    static let minimumSpread = 8

    public static func carriesPicture(_ image: CGImage) -> Bool {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        // Cannot sample it: keep the poster. Refusing one we failed to read
        // would throw away good frames to avoid blank ones.
        guard drawn else { return true }

        var lowest = UInt8.max
        var highest = UInt8.min
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                let value = pixels[index + channel]
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        return Int(highest) - Int(lowest) >= minimumSpread
    }
}
