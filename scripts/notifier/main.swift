import AppKit
import UserNotifications

// Claude Notifier.app
//
//   claude-notifier -daemon                 serve hook messages (started by the LaunchAgent via `open -a`)
//   claude-notifier -message TEXT [-title T] [-subtitle S] [-sound NAME]
//                                           post one notification and exit (installer self-test)

struct OneShot {
    var title = "Claude Notify"
    var subtitle = ""
    var message = ""
    var sound = "default"
}

func parseArgs() -> (oneShot: OneShot, daemon: Bool) {
    var shot = OneShot()
    var daemon = false
    let argv = CommandLine.arguments
    var i = 1
    func next() -> String? {
        i += 1
        return i < argv.count ? argv[i] : nil
    }
    while i < argv.count {
        switch argv[i] {
        case "-daemon": daemon = true
        case "-title": shot.title = next() ?? shot.title
        case "-subtitle": shot.subtitle = next() ?? ""
        case "-message": shot.message = next() ?? ""
        case "-sound": shot.sound = next() ?? "default"
        case "-help", "--help":
            print("""
            claude-notifier -daemon
            claude-notifier -message TEXT [-title T] [-subtitle S] [-sound NAME]
            """)
            exit(0)
        default: break
        }
        i += 1
    }
    return (shot, daemon)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let oneShot: OneShot
    private let daemon: Bool
    private let notifications = SystemNotifications()
    private var server: IPCServer?
    private var coordinator: Coordinator?

    init(oneShot: OneShot, daemon: Bool) {
        self.oneShot = oneShot
        self.daemon = daemon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if daemon && IPCServer.isAnotherInstanceRunning(path: Paths.socket) {
            log("[init] another instance is running, exiting")
            NSApp.terminate(nil)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                // The permission prompt needs a regular app for a moment.
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            DispatchQueue.main.async { self.notifications.setup(self.authorized) }
        }
    }

    private func authorized(_ granted: Bool) {
        NSApp.setActivationPolicy(.accessory)
        log("[init] notifications authorized=\(granted) daemon=\(daemon)")
        guard daemon else {
            postOneShot()
            return
        }
        let config = Config.load()
        let coordinator = Coordinator(config: config, notifications: notifications)
        let server = IPCServer(path: Paths.socket)
        server.onMessage = { json, connection in coordinator.handle(json, connection) }
        do {
            try server.start()
        } catch {
            log("[init] socket failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        self.coordinator = coordinator
        self.server = server
        Visibility.requestAccessibilityOnce()
    }

    private func postOneShot() {
        let content = UNMutableNotificationContent()
        content.title = oneShot.title
        content.subtitle = oneShot.subtitle
        content.body = oneShot.message
        content.sound = oneShot.sound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(oneShot.sound))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        }
    }
}

let (oneShot, daemon) = parseArgs()
if !daemon && oneShot.message.isEmpty {
    fputs("Error: -message is required (or use -daemon)\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate(oneShot: oneShot, daemon: daemon)
app.delegate = delegate
app.run()
