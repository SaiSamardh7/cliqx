import CleanPlayer
import SwiftUI

/// Shown once. The app's two non-obvious ideas are that the player controls are
/// native rather than part of the page, and that blocking can be turned off for
/// one site without turning it off everywhere. Neither is discoverable by
/// poking at it, so both are said plainly here.
struct OnboardingView: View {
    @ObservedObject var settings: ProtectionSettings

    @State private var page = 0

    private struct Panel {
        let symbol: String
        let title: String
        let body: String
    }

    private let panels = [
        Panel(symbol: "play.rectangle.on.rectangle",
              title: "A browser for watching",
              body: "Open any video site. Cliqx blocks the advertising "
                  + "and tracking requests, closes popups before they open, "
                  + "and hides the overlays that sit on top of the video."),
        Panel(symbol: "sparkles.tv",
              title: "Watch clean",
              body: "A Watch clean button appears on the video. It clears the "
                  + "page away and gives you the video with native controls — "
                  + "including next and previous episode, which the system "
                  + "player does not have.\n\nWhere the platform supports it, "
                  + "Open in the system player hands playback to Apple's "
                  + "player instead, with AirPlay and picture in picture."),
        Panel(symbol: "shield.lefthalf.filled",
              title: "You are in control",
              body: "Protection is on by default. If a site will not work, "
                  + "turn it off for that site alone from the menu next to the "
                  + "address — everywhere else stays protected.\n\nBlocking "
                  + "by shape occasionally catches a real dialog. The shield "
                  + "button in the toolbar puts it back."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(panels.indices, id: \.self) { index in
                    panelView(panels[index]).tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 0) {
                Button(page == panels.count - 1 ? "Start browsing" : "Next") {
                    if page == panels.count - 1 {
                        settings.hasOnboarded = true
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.accentColor, in: .rect(cornerRadius: 14))
                .foregroundStyle(.white)
                .padding(20)

                Button("Skip") { settings.hasOnboarded = true }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    .opacity(page == panels.count - 1 ? 0 : 1)
                    .accessibilityHidden(page == panels.count - 1)
            }
            // Matches the text measure so the button does not run the width of
            // a 13-inch iPad.
            .frame(maxWidth: 460)
        }
        .background(Color(.systemBackground))
    }

    private func panelView(_ panel: Panel) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)
            Image(systemName: panel.symbol)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(panel.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(panel.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 40)
        }
        // Keeps the measure readable on iPad, where a full-width paragraph runs
        // to well over a hundred characters a line.
        .frame(maxWidth: 460)
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
    }
}
