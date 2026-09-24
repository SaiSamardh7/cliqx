import Foundation

/// Playback choices that outlive one video: how subtitles look, and the
/// picture adjustments a badly-mastered source needs.
///
/// On the device only, like every other preference here.
@MainActor
public final class PlaybackPreferences: ObservableObject {
    @Published public var subtitles: SubtitleStyle {
        didSet { save(subtitles, as: Keys.subtitles) }
    }

    private enum Keys {
        static let subtitles = "playback.subtitleStyle.v1"
    }

    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
        subtitles = StoreRecovery.decode(SubtitleStyle.self,
                                         from: store.data(forKey: Keys.subtitles),
                                         named: Keys.subtitles)
            ?? SubtitleStyle()
    }

    private func save<T: Encodable>(_ value: T, as key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key)
    }
}
