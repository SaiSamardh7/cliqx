import CleanPlayer
import MediaPlayer
import SwiftUI
import UIKit

/// A slim vertical slider in the player's margin, dragged directly.
///
/// The same shape as `PlayerLevelHUD`, which is deliberate: the HUD that
/// appears mid-swipe and the slider that sits in the margin are the same
/// control seen two ways, so neither teaches a level the other contradicts.
struct PlayerEdgeSlider: View {
    let symbol: String
    let fraction: Double
    let accent: Color
    let label: String
    /// 0...1 from the bottom of the track.
    let onChange: (Double) -> Void

    private static let trackHeight: CGFloat = 132

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(accent.opacity(0.9))

            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color(white: 1, opacity: 0.22))
                    Capsule()
                        .fill(accent)
                        .frame(height: geometry.size.height * min(max(fraction, 0), 1))
                }
                // The whole column is the target, not the 8pt capsule: a
                // finger is wider than the track it is aiming at.
                .contentShape(Rectangle().inset(by: -16))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let height = Double(max(geometry.size.height, 1))
                            let ratio = Double(value.location.y) / height
                            // Inverted: a track fills from the bottom, but a
                            // touch is measured from the top.
                            onChange(1 - min(max(ratio, 0), 1))
                        }
                )
            }
            .frame(width: 8, height: Self.trackHeight)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(white: 0, opacity: 0.28)))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            onChange(min(max(fraction + (direction == .increment ? 0.1 : -0.1), 0), 1))
        }
    }
}

/// The system volume slider, turned on its side to sit in the player's margin.
///
/// It has to be `MPVolumeView` rather than something matching
/// `PlayerEdgeSlider`, and the difference in appearance is the honest cost of
/// the only supported route: iOS lets an app *show* this control and lets the
/// user drag it, and offers nothing at all for setting device volume in code.
/// Driving a slider found inside its `subviews` is what the app used to do, and
/// it is an undocumented view hierarchy that Apple has rejected apps over.
///
/// Rotated by -90°: sized horizontally first, turned, then given the vertical
/// footprint it should occupy, because `rotationEffect` does not change layout.
///
/// Track length, padding and backing deliberately match `PlayerEdgeSlider`, so
/// the two margins read as one pair of controls rather than as the app's slider
/// beside a system one that wandered in. The post-rotation width is the thumb's,
/// not the control's: `frame` does not clip, so the slider still draws in full.
///
/// Renders nothing in the Simulator — there is no audio route for it to attach
/// to — so it can only be judged on a device.
struct VerticalSystemVolumeSlider: View {
    private static let trackHeight: CGFloat = 132

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))

            SystemVolumeSlider()
                .frame(width: Self.trackHeight, height: 28)
                .rotationEffect(.degrees(-90))
                .frame(width: 14, height: Self.trackHeight)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(white: 0, opacity: 0.28)))
        .accessibilityLabel("Device volume")
    }
}
