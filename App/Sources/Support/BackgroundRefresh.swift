#if os(iOS)
import Foundation
import BackgroundTasks

/// iOS background app refresh: iOS wakes the app every so often (at most every 15 minutes, as the system sees fit)
/// to check the Inbox, so new-mail notifications and the badge stay current while the app is closed.
enum BackgroundRefresh {
    static let id = "ai.slyy.mailr.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func run() async {
        schedule() // keep the chain going
        await AppModel.shared.backgroundCheck()
    }
}
#endif
