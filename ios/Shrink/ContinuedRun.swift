import BackgroundTasks
import Foundation

/// iOS 26 and later: asks iPhone to let a Free up space batch keep going after the person leaves Shrink,
/// with iPhone's own progress display and stop button. The batch itself runs as usual; this only keeps
/// the app awake and reports progress. On earlier iOS (or if iPhone says no) `start` returns nil and the
/// batch runs while Shrink is open, as before.
///
/// Unproven on a real iPhone (the simulator can't run these tasks). Everything around it fails safe: a
/// video interrupted in the background is never counted as done, and the batch waits for "Keep going".
@MainActor
final class ContinuedRun {
    /// Listed in Info.plist as "com.useshrink.app.freeup.*". Each batch gets its own identifier, because
    /// registering one twice ends the app.
    private static let prefix = "com.useshrink.app.freeup"
    private static let title = "Shrinking your videos"

    private let onExpire: @MainActor () -> Void
    private var task: BGTask?
    private var fraction: Double = 0
    private var subtitle: String
    /// Finished before iPhone handed over the task: complete it the moment it arrives.
    private var endedEarly: (success: Bool, subtitle: String)?

    private init(subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        self.subtitle = subtitle
        self.onExpire = onExpire
    }

    /// Call from the person's tap, while Shrink is open (iPhone only allows it then).
    static func start(subtitle: String, onExpire: @escaping @MainActor () -> Void) -> ContinuedRun? {
        guard #available(iOS 26.0, *) else { return nil }
        let run = ContinuedRun(subtitle: subtitle, onExpire: onExpire)
        let identifier = "\(prefix).\(Int(Date().timeIntervalSince1970 * 1000))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak run] task in
            MainActor.assumeIsolated {
                guard let run else {
                    task.setTaskCompleted(success: false)
                    return
                }
                run.attach(task)
            }
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Start now or not at all: a batch that starts later, unasked, would be a surprise.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            return nil
        }
        return run
    }

    /// Progress across the whole batch, 0 to 1, and the line under the title ("Video 2 of 5").
    func update(fraction: Double, subtitle: String) {
        self.fraction = min(max(fraction, 0), 1)
        let changed = subtitle != self.subtitle
        self.subtitle = subtitle
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(self.fraction * 1000)
        if changed { task.updateTitle(Self.title, subtitle: subtitle) }
    }

    /// The batch is over (finished, stopped or paused). The task is handed back to iPhone.
    func finish(success: Bool, subtitle: String) {
        guard let task else {
            endedEarly = (success, subtitle)
            return
        }
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.updateTitle(Self.title, subtitle: subtitle)
        }
        task.setTaskCompleted(success: success)
        self.task = nil
    }

    private func attach(_ task: BGTask) {
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        self.task = continued
        continued.progress.totalUnitCount = 1000
        continued.progress.completedUnitCount = Int64(fraction * 1000)
        continued.updateTitle(Self.title, subtitle: subtitle)
        continued.expirationHandler = { [weak self] in
            // iPhone needs the room back, or the person tapped stop in iPhone's progress display.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.expired()
                }
            }
        }
        if let ended = endedEarly {
            endedEarly = nil
            finish(success: ended.success, subtitle: ended.subtitle)
        }
    }

    private func expired() {
        guard let task else { return }
        task.setTaskCompleted(success: false)
        self.task = nil
        onExpire()
    }
}
