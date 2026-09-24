import AVFoundation
import Foundation

/// The app's audio session.
///
/// Process-wide, not per-player: the category governs WebKit's media as much
/// as an `AVPlayer`'s, which matters because today everything plays through a
/// `WKWebView`.
///
/// Without this the `audio` background mode in Info.plist is an empty
/// declaration. The default session category is `.soloAmbient`, which is
/// silenced by the ring switch and stops on lock — so Picture in Picture,
/// which the app already enables, would suspend the moment it was most
/// wanted, and AirPlay to a receiver would cut out when the phone locked.
public enum MediaSession {
    /// `.playback` with `.moviePlayback` is Apple's documented pairing for a
    /// video player: it keeps audio going when the screen locks or the app is
    /// backgrounded, and it ignores the ring switch — correct here, because
    /// someone watching a film has already said what they want.
    ///
    /// Returns rather than throws at the call site: a session that will not
    /// activate is worth knowing about, but it is not a reason to refuse to
    /// start a browser.
    @discardableResult
    public static func activate() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            active = true
            return true
        } catch {
            NSLog("[cliqx] audio session did not activate: %@",
                  error.localizedDescription)
            return false
        }
    }

    /// Give the session back when no player needs it.
    ///
    /// `.playback` interrupts whatever else was making sound, and without this
    /// the interruption never ends: a podcast paused when the user opened a
    /// video stayed paused after they closed it, for the life of the process.
    /// `.notifyOthersOnDeactivation` is what tells the other app it may resume.
    ///
    /// Safe to call when nothing was activated, and deliberately quiet about
    /// failure — deactivating while a sound is still finishing throws, and
    /// there is nothing useful to do about it.
    @discardableResult
    public static func deactivate() -> Bool {
        guard active else { return true }
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
            active = false
            return true
        } catch {
            NSLog("[cliqx] audio session did not deactivate: %@",
                  error.localizedDescription)
            return false
        }
    }

    /// Whether this app last claimed the session. Not the same question as
    /// `AVAudioSession.isOtherAudioPlaying`, and cheaper than asking.
    public private(set) static var active = false
}
