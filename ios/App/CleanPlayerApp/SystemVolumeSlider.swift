import MediaPlayer
import SwiftUI
import UIKit

/// The system volume slider, shown rather than driven.
///
/// `MPVolumeView` is the only supported way an app can offer device volume, and
/// the support is one-directional: the user drags it and iOS changes the
/// volume. Reaching into `subviews` for the `UISlider` and calling
/// `setValue(_:animated:)` is what the app used to do, and it was removed for
/// good reason — the view hierarchy is undocumented, Apple has rejected apps
/// over it, and recent iOS ignores the write anyway.
///
/// So this is deliberately a *view*, not a control the gesture can reach. The
/// vertical swipe cannot drive it, and that is the platform's answer rather
/// than an omission: device volume on iOS belongs to the hardware buttons and
/// to this slider. Media gain, which the app does own, is separate — see
/// `PlayerVolume`.
///
/// Its *appearance*, unlike its behaviour, is ours. `setMinimumVolumeSliderImage`,
/// `setMaximumVolumeSliderImage` and `setVolumeThumbImage` are public API, so
/// the track is drawn to match `PlayerEdgeSlider` instead of inheriting system
/// defaults. That matters beyond tidiness: tinting the whole control white left
/// a white thumb sitting on a white filled track, so at high volume the slider
/// was a featureless white slab showing neither level nor handle.
///
/// It does not render in the Simulator. There is no audio route there to
/// attach to, so the slider is simply absent; it only shows on a device.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        // The route picker lives in the player's top bar already.
        view.showsRouteButton = false
        view.setMinimumVolumeSliderImage(Self.filledTrack, for: .normal)
        view.setMaximumVolumeSliderImage(Self.emptyTrack, for: .normal)
        view.setVolumeThumbImage(Self.thumb, for: .normal)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    /// Matches `PlayerEdgeSlider`: an 8pt capsule, white where filled and 22%
    /// white where not. Drawn rather than bundled so there is no asset to keep
    /// in step with the SwiftUI control it has to resemble.
    private static func track(_ color: UIColor) -> UIImage {
        let height = 8.0
        // Wide enough to hold both round caps plus one stretchable column.
        let width = height + 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
            .image { _ in
                color.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                             cornerRadius: height / 2).fill()
            }
        // Stretch the middle column only, so the caps stay round at any length.
        let cap = height / 2
        return image.resizableImage(
            withCapInsets: UIEdgeInsets(top: 0, left: cap, bottom: 0, right: cap),
            resizingMode: .stretch)
    }

    private static let filledTrack = track(.white)
    private static let emptyTrack = track(UIColor(white: 1, alpha: 0.22))

    /// The default thumb is sized for a settings row and looks lost on a dark
    /// player. The ring is not decoration: on a nearly full track the thumb is
    /// white on white, and without it there is no handle to see or aim at.
    private static let thumb: UIImage = {
        let side = 14.0
        let inset = 0.75
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            .image { _ in
                let circle = UIBezierPath(ovalIn: CGRect(x: inset, y: inset,
                                                         width: side - inset * 2,
                                                         height: side - inset * 2))
                UIColor.white.setFill()
                circle.fill()
                UIColor(white: 0, alpha: 0.45).setStroke()
                circle.lineWidth = inset * 2
                circle.stroke()
            }
    }()
}
