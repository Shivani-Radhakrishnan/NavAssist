import BlindNavCore
import Observation
import UIKit

/// Obstacle warnings on their own, with no map: the iPhone version of step11.py.
@Observable
final class ObstacleSession {
    private(set) var problem: String?
    private(set) var detector: String?
    private(set) var blocked = [false, false, false]

    private let app: AppServices
    private var announcer = ObstacleAnnouncer()

    init(app: AppServices) {
        self.app = app
    }

    func begin() {
        UIApplication.shared.isIdleTimerDisabled = true
        let (source, problem) = ObstacleSources.best(warnDistance: app.settings.warnDistance)
        self.problem = problem
        detector = source?.kind
        announcer.phrasing = app.settings.phrasing
        app.ar.onPose = nil
        app.ar.onTrackingChange = nil
        source?.onReading = { [weak self] reading, t in
            guard let self else { return }
            self.app.handle(self.announcer.update(reading, time: t))
            self.blocked = self.announcer.blocked
        }
        app.ar.obstacleSource = source
        app.ar.start()
        if let problem {
            app.speaker.say(problem, urgent: true)
        } else {
            app.speaker.say("Obstacle detection on. Hold the phone upright at chest height, camera facing forward.", urgent: true)
        }
    }

    func end() {
        UIApplication.shared.isIdleTimerDisabled = false
        app.speaker.stop()
        app.ar.stop()
    }
}
