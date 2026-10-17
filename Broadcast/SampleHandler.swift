// Stem Eye -- the ReplayKit broadcast extension: iPadOS hands it every screen frame while the broadcast runs (started from the
// app's button or Control Center). All the work is in Pipeline; this only connects it to ReplayKit.
import ReplayKit
import CoreMedia

final class SampleHandler: RPBroadcastSampleHandler {
    private let pipe = Pipeline()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        if let why = pipe.start() {
            finishBroadcastWithError(NSError(domain: "StemEye", code: 1, userInfo: [NSLocalizedDescriptionKey: why]))
        }
    }

    override func broadcastPaused() { pipe.pause(true) }

    override func broadcastResumed() { pipe.pause(false) }

    override func broadcastFinished() { pipe.stop() }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }     // no sound: the Controller listens through the Pi
        let o = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value
        pipe.video(sampleBuffer, orientation: o)
    }
}
