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
/// It does not render in the Simulator. There is no audio route there to
/// attach to, so the slider is simply absent; it only shows on a device.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        // The route picker lives in the player's top bar already.
        view.showsRouteButton = false
        view.setVolumeThumbImage(Self.thumb, for: .normal)
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    /// The default thumb is sized for a settings row and looks lost on a dark
    /// player. Drawn rather than bundled so there is no asset to keep in step.
    private static let thumb: UIImage = {
        let side = 14.0
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            .image { _ in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            }
    }()
}

/// The device-volume row offered inside the player.
///
/// Always present and always working, whatever the stream is: this is the
/// iPhone's own volume, so MSE, DRM and cross-origin make no difference to it.
/// That is the whole point — it is the control that survives everything the
/// media-gain path cannot do.
struct DeviceVolumeRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Device volume", systemImage: "iphone.gen3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                SystemVolumeSlider()
                    .frame(height: 28)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Same as the buttons on the side of your iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
