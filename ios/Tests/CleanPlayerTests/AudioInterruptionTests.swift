import AVFoundation
import XCTest
@testable import CleanPlayer

final class AudioInterruptionTests: XCTestCase {
    func testBeganIsRecognised() {
        let event = AudioInterruptions.interruption(from: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        XCTAssertEqual(event, .began)
    }

    /// iOS says whether the other app is finished. A call that is still going
    /// ends with shouldResume false, and resuming then talks over it.
    func testEndedCarriesWhetherToResume() {
        let resume = AudioInterruptions.interruption(from: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ])
        XCTAssertEqual(resume, .ended(shouldResume: true))

        let stay = AudioInterruptions.interruption(from: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        ])
        XCTAssertEqual(stay, .ended(shouldResume: false))
    }

    func testUnrelatedPayloadIsIgnored() {
        XCTAssertNil(AudioInterruptions.interruption(from: nil))
        XCTAssertNil(AudioInterruptions.interruption(from: ["something": 1]))
    }

    /// Headphones out: pause. This is the case the rule exists for.
    func testOldDeviceUnavailableIsADeviceLoss() {
        XCTAssertTrue(AudioInterruptions.isOutputDeviceLost([
            AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        ]))
    }

    /// Headphones IN, or a category change, is not a reason to pause.
    func testOtherRouteChangesAreNotADeviceLoss() {
        for reason: AVAudioSession.RouteChangeReason in [
            .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange,
        ] {
            XCTAssertFalse(AudioInterruptions.isOutputDeviceLost([
                AVAudioSessionRouteChangeReasonKey: reason.rawValue,
            ]), "\(reason) should not pause playback")
        }
        XCTAssertFalse(AudioInterruptions.isOutputDeviceLost(nil))
    }
}
