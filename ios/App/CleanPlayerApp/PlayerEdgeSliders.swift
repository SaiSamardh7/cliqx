import CleanPlayer
import SwiftUI

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
    /// Spoken after the label, so the dimmed state can say why.
    var hint: String = ""
    /// Dimmed and inert, but still drawn and still taking up its space.
    ///
    /// A control that appears when a handoff lands moves everything beside it
    /// and changes what the margin under a thumb does mid-film. Showing it
    /// from the start, visibly not yet live, costs a little ink and keeps the
    /// margin the same shape for the whole video.
    var isEnabled: Bool = true
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
                .allowsHitTesting(isEnabled)
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
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            onChange(min(max(fraction + (direction == .increment ? 0.1 : -0.1), 0), 1))
        }
    }
}
