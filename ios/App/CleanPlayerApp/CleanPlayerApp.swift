import CleanPlayer
import SwiftUI

@main
struct CleanPlayerApp: App {
    @StateObject private var model = BrowserModel()
    @StateObject private var settings = ProtectionSettings()
    @StateObject private var rules = RuleListController()

    var body: some Scene {
        WindowGroup {
            Group {
                if !settings.hasOnboarded {
                    OnboardingView(settings: settings)
                } else if let url = model.current {
                    BrowserView(url: url, model: model, rules: rules, settings: settings)
                } else {
                    HomeView(model: model, rules: rules, settings: settings)
                }
            }
            .task {
                // Compiling EasyList takes ~10s the first time and a few
                // milliseconds afterwards. Starting at launch — not at first
                // navigation — is what keeps that cost off the critical path.
                rules.begin(settings.level)
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
