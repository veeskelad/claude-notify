import Foundation
import UserNotifications
import AppKit

// MARK: - Logging

private let logPath = "/tmp/claude-notifier/notifier.log"

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

// MARK: - Notification Data

struct NotificationArgs {
    var title = "Terminal"
    var subtitle = ""
    var message = ""
    var sound = "default"
    var activate = ""
    var cwd = ""
}

func parseArgs() -> (args: NotificationArgs, isDaemon: Bool) {
    var args = NotificationArgs()
    var isDaemon = false
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "-daemon":
            isDaemon = true
        case "-title":
            i += 1; if i < argv.count { args.title = argv[i] }
        case "-subtitle":
            i += 1; if i < argv.count { args.subtitle = argv[i] }
        case "-message":
            i += 1; if i < argv.count { args.message = argv[i] }
        case "-sound":
            i += 1; if i < argv.count { args.sound = argv[i] }
        case "-activate":
            i += 1; if i < argv.count { args.activate = argv[i] }
        case "-help", "--help":
            print("""
            claude-notifier — macOS notification tool using UNUserNotificationCenter

            Usage:
              claude-notifier -message VALUE [options]     # One-shot mode
              claude-notifier -daemon                      # Daemon mode

              -title VALUE       Notification title (default: Terminal)
              -subtitle VALUE    Notification subtitle
              -message VALUE     Notification message (required in one-shot mode)
              -sound NAME        Sound name (default, Glass, Pop, Funk, etc.)
              -activate ID       Bundle ID of app to activate on click
              -daemon            Daemon mode: watch inbox file for JSON lines
              -help              Show this help

            Daemon mode watches /tmp/claude-notifier/inbox for JSON lines:
              {"title":"...","subtitle":"...","message":"...","sound":"...","activate":"..."}
            """)
            exit(0)
        default:
            break
        }
        i += 1
    }
    return (args, isDaemon)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let initialArgs: NotificationArgs
    let isDaemon: Bool
    static let inboxPath = "/tmp/claude-notifier/inbox"

    init(args: NotificationArgs, isDaemon: Bool) {
        self.initialArgs = args
        self.isDaemon = isDaemon
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }

                if let error = error {
                    fputs("Error: \(error.localizedDescription)\n", stderr)
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }
                if !granted {
                    fputs("Error: notification permission not granted\n", stderr)
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }

                if self.isDaemon {
                    self.startDaemon()
                } else {
                    self.postNotification(self.initialArgs)
                }
            }
        }
    }

    // MARK: - Daemon mode (watches inbox file for JSON lines)

    func startDaemon() {
        let path = AppDelegate.inboxPath
        let fm = FileManager.default

        // Ensure inbox file exists
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Start reading from beginning — catches notifications written
            // during daemon startup (race condition with watcher).
            // Truncate first to avoid replaying stale entries from previous run.
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
            var offset: UInt64 = 0

            while true {
                Thread.sleep(forTimeInterval: 0.3)

                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                handle.seek(toFileOffset: offset)
                let data = handle.readDataToEndOfFile()
                handle.closeFile()

                if data.isEmpty { continue }
                offset += UInt64(data.count)

                guard let text = String(data: data, encoding: .utf8) else { continue }
                for line in text.components(separatedBy: "\n") {
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: String]
                    else { continue }

                    let args = NotificationArgs(
                        title: json["title"] ?? "Terminal",
                        subtitle: json["subtitle"] ?? "",
                        message: json["message"] ?? "",
                        sound: json["sound"] ?? "default",
                        activate: json["activate"] ?? "",
                        cwd: json["cwd"] ?? ""
                    )

                    DispatchQueue.main.async {
                        self.postNotification(args)
                    }
                }

                // Truncate inbox if it gets too large (> 64KB)
                if offset > 65536 {
                    try? "".write(toFile: path, atomically: true, encoding: .utf8)
                    offset = 0
                }
            }
        }
    }

    // MARK: - Post notification

    func postNotification(_ args: NotificationArgs) {
        let content = UNMutableNotificationContent()
        content.title = args.title
        if !args.subtitle.isEmpty {
            content.subtitle = args.subtitle
        }
        content.body = args.message

        if args.sound == "default" {
            content.sound = .default
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(args.sound))
        }

        var info: [String: String] = [:]
        if !args.activate.isEmpty { info["activate"] = args.activate }
        if !args.cwd.isEmpty { info["cwd"] = args.cwd }
        if !info.isEmpty { content.userInfo = info }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                fputs("Error: \(error.localizedDescription)\n", stderr)
            }
        }

        if !isDaemon {
            // One-shot mode: auto-exit after 5 minutes
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                NSApp.terminate(nil)
            }
        }
    }

    // Show banner + sound even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Handle notification click
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        log("[click] didReceive called, userInfo=\(userInfo)")

        let bundleId = userInfo["activate"] as? String ?? ""
        let cwd = userInfo["cwd"] as? String ?? ""

        if !bundleId.isEmpty {
            log("[click] activate bundleId=\(bundleId) cwd=\(cwd)")
            activateApp(bundleId: bundleId, cwd: cwd)
        }
        completionHandler()
        if !isDaemon {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // Activate target app, focusing the window matching cwd (works across fullscreen Spaces)
    private func activateApp(bundleId: String, cwd: String = "") {
        // Check: already in the correct window? Skip activation to avoid opening a new window.
        if !cwd.isEmpty, let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier == bundleId {
            let basename = (cwd as NSString).lastPathComponent
            let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
            var focusedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
            if let focusedWindow = focusedRef {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""
                if title.contains(basename) {
                    log("[click] already in '\(basename)', skipping")
                    return
                }
            }
        }

        // Strategy 1: open -b with cwd — macOS switches to the correct fullscreen Space
        if !cwd.isEmpty {
            let basename = (cwd as NSString).lastPathComponent
            log("[click] strategy 1: open -b \(bundleId) \(cwd)")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", bundleId, cwd]
            do {
                try proc.run()
                proc.waitUntilExit()
                log("[click] strategy 1 exit=\(proc.terminationStatus)")
                if proc.terminationStatus == 0 { return }
            } catch {
                log("[click] strategy 1 failed: \(error.localizedDescription)")
            }
        }

        // Strategy 2: osascript Apple Events — activate app (any window)
        log("[click] strategy 2: osascript activate \(bundleId)")
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "tell application id \"\(bundleId)\" to activate"]
        do {
            try script.run()
            script.waitUntilExit()
            if script.terminationStatus == 0 {
                log("[click] strategy 2 success")
                return
            }
            log("[click] strategy 2 exit=\(script.terminationStatus)")
        } catch {
            log("[click] strategy 2 failed: \(error.localizedDescription)")
        }

        // Strategy 3: open -b without path (Launch Services fallback)
        log("[click] strategy 3: open -b \(bundleId)")
        let proc3 = Process()
        proc3.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc3.arguments = ["-b", bundleId]
        do {
            try proc3.run()
            proc3.waitUntilExit()
            log("[click] strategy 3 exit=\(proc3.terminationStatus)")
        } catch {
            log("[click] strategy 3 failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Main

let (parsedArgs, isDaemon) = parseArgs()

if !isDaemon && parsedArgs.message.isEmpty {
    fputs("Error: -message is required (or use -daemon mode)\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let appDelegate = AppDelegate(args: parsedArgs, isDaemon: isDaemon)
app.delegate = appDelegate
app.run()
