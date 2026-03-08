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

                log("[init] authorized=\(granted) isDaemon=\(self.isDaemon)")
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
        log("[daemon] startDaemon called")
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
                log("[daemon] read \(data.count) bytes from inbox")

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

    private func activateApp(bundleId: String, cwd: String = "") {
        // Use osascript "activate" — works across fullscreen Spaces.
        // Do NOT use "open -b <app> <path>": VS Code forks open a new window.
        // Do NOT use "open -b <app>" without path: doesn't switch fullscreen Spaces.
        log("[click] activate \(bundleId) via osascript")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application id \"\(bundleId)\" to activate"]
        do {
            try proc.run()
            proc.waitUntilExit()
            log("[click] osascript exit=\(proc.terminationStatus)")
        } catch {
            log("[click] osascript failed: \(error.localizedDescription)")
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
