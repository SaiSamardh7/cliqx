import UIKit

/// What the app is willing to rotate to, and how a player narrows that.
///
/// `requestGeometryUpdate` does not simply turn the screen: it REPLACES the
/// scene's supported orientations with the ones passed. Asking for `.landscape`
/// therefore means "this app only supports landscape from now on" — the scene
/// stops following the device, and it stays that way after the player closes,
/// because nothing put the original set back.
///
/// So a player that rotates has to restore, and what it restores to is what the
/// app declared in its Info.plist rather than a guess: an iPad allows upside
/// down and an iPhone does not, and hard-coding either is wrong somewhere.
public enum InterfaceOrientationPolicy {
    /// The `UISupportedInterfaceOrientations` key for this idiom, as UIKit
    /// spells it in the plist.
    public static func plistKey(for idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .pad: "UISupportedInterfaceOrientations~ipad"
        default: "UISupportedInterfaceOrientations"
        }
    }

    /// Maps the plist's orientation names to a mask.
    ///
    /// Unknown names are ignored rather than failing the whole mask; an empty
    /// or unusable list falls back to `.allButUpsideDown`, which is the
    /// conservative answer for a video app on a phone.
    public static func mask(from names: [String]) -> UIInterfaceOrientationMask {
        var mask: UIInterfaceOrientationMask = []
        for name in names {
            switch name {
            case "UIInterfaceOrientationPortrait":
                mask.insert(.portrait)
            case "UIInterfaceOrientationPortraitUpsideDown":
                mask.insert(.portraitUpsideDown)
            case "UIInterfaceOrientationLandscapeLeft":
                // UIKit's plist names are the DEVICE orientation, which is the
                // opposite of the interface one. Getting this pair backwards
                // is silent: the mask is still non-empty and still rotates.
                mask.insert(.landscapeLeft)
            case "UIInterfaceOrientationLandscapeRight":
                mask.insert(.landscapeRight)
            default:
                continue
            }
        }
        return mask.isEmpty ? .allButUpsideDown : mask
    }

    /// Everything the app declared it supports, for the current device.
    public static func declared(
        bundle: Bundle = .main,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) -> UIInterfaceOrientationMask {
        let names = bundle.object(forInfoDictionaryKey: plistKey(for: idiom)) as? [String]
        return mask(from: names ?? [])
    }

    /// The single orientation a rotate button asks for: whichever one the
    /// scene is not in.
    public static func flipped(from current: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        current.isLandscape ? .portrait : .landscape
    }

    /// The interface orientation matching how the device is being held, or nil
    /// when the device cannot say — flat on a table, or face down.
    ///
    /// Restoring the full set of orientations is NOT enough to undo a rotate
    /// button. Landscape is still in that set, so UIKit has no reason to leave
    /// it and waits for a device-orientation change that never comes for a
    /// phone already being held still. The app has to be sent back explicitly,
    /// and this is where it should land.
    ///
    /// Note the inversion: a device rotated left presents a right-hand
    /// landscape interface. Getting the pair backwards is silent — the screen
    /// still rotates, just to the upside-down version.
    public static func mask(matching device: UIDeviceOrientation) -> UIInterfaceOrientationMask? {
        switch device {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }

    /// Where to send the interface when a player stops forcing an orientation.
    ///
    /// The device's own orientation is the better answer when it can be had:
    /// the phone is in someone's hands and that is where they expect the screen
    /// to face. But it often cannot be had — a phone flat on a table reports
    /// `.faceUp`, a simulator has no accelerometer and reports `.unknown` — and
    /// falling back to "do nothing" is what leaves the app stuck in the
    /// orientation the button chose. `before` is the interface orientation from
    /// the moment the button first narrowed things, which is the honest answer
    /// to "put it back".
    public static func restoreTarget(
        device: UIDeviceOrientation,
        before: UIInterfaceOrientation?,
        allowed: UIInterfaceOrientationMask
    ) -> UIInterfaceOrientationMask? {
        if let wanted = mask(matching: device), allowed.contains(wanted) { return wanted }
        guard let before, let wanted = mask(matchingInterface: before),
              allowed.contains(wanted) else { return nil }
        return wanted
    }

    /// An interface orientation as a single-value mask. Named apart from the
    /// device overload on purpose: `.unknown` and `.portraitUpsideDown` exist
    /// in both enums, so a bare case would be ambiguous at every call site.
    public static func mask(matchingInterface interface: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch interface {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }
}
