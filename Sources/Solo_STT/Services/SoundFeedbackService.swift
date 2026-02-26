import AppKit

class SoundFeedbackService {
    private var startSound: NSSound?
    private var stopSound: NSSound?

    init() {
        startSound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
        stopSound = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)
    }

    func playStart() {
        startSound?.stop()
        startSound?.play()
    }

    func playStop() {
        stopSound?.stop()
        stopSound?.play()
    }
}
