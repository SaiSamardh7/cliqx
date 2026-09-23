import CleanPlayer
import SwiftUI
import UIKit

@main
struct CleanPlayerApp: App {
    @StateObject private var model = BrowserModel()
    @StateObject private var settings = ProtectionSettings()
    @StateObject private var gestureSettings = PlayerGestureSettings()
    @StateObject private var rules = RuleListController()

    var body: some Scene {
        WindowGroup {
            Group {
                if !settings.hasOnboarded {
                    OnboardingView(settings: settings)
                } else if let url = model.current {
                    BrowserView(url: url, model: model, rules: rules, settings: settings,
                                gestureSettings: gestureSettings)
                } else {
                    HomeView(model: model, rules: rules, settings: settings,
                             gestureSettings: gestureSettings)
                }
            }
            .task {
                // Compiling EasyList takes ~10s the first time and a few
                // milliseconds afterwards. Starting at launch — not at first
                // navigation — is what keeps that cost off the critical path.
                rules.begin(settings.level)
                Diagnostics.start()
                // `UIDevice.current.orientation` reads `.unknown` until this is
                // asked for. The player's rotate button needs it: undoing that
                // button means sending the interface back to where the device
                // actually is, and "unknown" would leave it stuck in the
                // orientation the button chose.
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
        }
    }
}

/// The injected page agent, loaded once from the bundle.
enum Agent {
    static let popupGuard: String = bundled("popupguard")
    static let source: String = bundled("agent")

    private static func bundled(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("\(name).js missing from the bundle")
            return ""
        }
        return js
    }
}
