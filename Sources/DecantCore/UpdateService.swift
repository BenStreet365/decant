import Foundation
import Synchronization
import XPC

/// Lets users ask for the newest release of decant without root: Check for Updates in Decant.app
/// and `decant update --latest` send a request to this service, which the
/// `uk.street365.decant.update-service` LaunchDaemon runs as root on demand (`decant
/// _update-service`). It runs `Updater` in `.requested` mode, so the update is installed straight
/// away unless a profile turns updates off or holds them back. A request carries nothing the
/// service acts on: it only ever installs the newest release from GitHub that passes every check.
public enum UpdateService {
    public static let label = "\(Configuration.domain).update-service"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// The service exits once it has had no request for this long; launchd starts it again for the next.
    static let idleExit: TimeInterval = 60

    struct Request: Codable {}

    /// Asks the service to install the newest release, waiting until it has finished, which can
    /// take several minutes. Throws if the service cannot be reached.
    public static func requestUpdate() throws -> UpdateReport {
        // XPC's errors say little more than "error 1", so neither is passed on.
        let unreachable = DecantError(.updateFailed, "Cannot reach the update service (\(label)). Installing decant's package again sets it up.")
        guard let session = try? XPCSession(machService: label) else { throw unreachable }
        defer { session.cancel(reason: "Done") }
        do {
            return try session.sendSync(Request())
        } catch is DecodingError {
            throw DecantError(.updateFailed, "The update service sent a reply this version of decant cannot read")
        } catch {
            throw unreachable
        }
    }

    /// Run by launchd as root. Handles one request at a time, each with a fresh `Updater` from
    /// `makeUpdater` (so a new profile applies), and exits once idle.
    public static func listen(makeUpdater: @escaping @Sendable () -> Updater) throws -> Never {
        struct Activity { var running = 0; var last = Date() }
        let activity = Mutex(Activity())
        let serial = NSLock()
        let listener = try XPCListener(service: label) { request in
            request.accept { (_: Request) -> (any Encodable)? in
                activity.withLock { $0.running += 1 }
                defer { activity.withLock { $0.running -= 1; $0.last = Date() } }
                serial.lock()
                defer { serial.unlock() }
                let updater = makeUpdater()
                updater.log.info("A user asked for the newest version of decant")
                return updater.run(checkOnly: false, mode: .requested)
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + idleExit, repeating: 10)
        timer.setEventHandler {
            let idle = activity.withLock { $0.running == 0 && Date().timeIntervalSince($0.last) >= idleExit }
            if idle { exit(0) }
        }
        timer.resume()
        withExtendedLifetime(listener) { dispatchMain() }
    }
}
