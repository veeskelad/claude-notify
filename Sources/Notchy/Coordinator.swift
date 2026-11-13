import AppKit
import SwiftUI

// Ties hook messages, visibility, the notch and system notifications together.
// Everything here runs on the main queue.
//
// A PermissionRequest hook waits on its socket while Claude Code shows its own
// dialog in parallel; whichever answers first wins. So a pending request is only
// *presented* (banner, sound, fallback notification) while its session is off screen.
// Once announced it stays reachable in the notch until it is answered anywhere; it is
// released (reply "pass") as soon as the session moves on: tool finished, turn ended,
// new prompt.

final class PendingRequest {
    let id: String
    let session: SessionState
    let card: Card
    let match: String
    let agentId: String     // set when a subagent asked; the main turn ending doesn't resolve it
    let connection: Connection
    var presented = false
    var announced = false   // shown once: keeps its rim dot and card until answered, even on screen
    var soundPlayed = false
    var noticed = false     // the user hovered or clicked it: no fallback notification needed
    var dismissed = false   // the user hid it; the dialog in the session stays
    var fallbackAt: Date?
    var fallbackPosted = false
    let createdAt = Date()
    var checkedAt = Date.distantPast
    var checking = false

    init(id: String, session: SessionState, card: Card, match: String, agentId: String, connection: Connection) {
        self.id = id
        self.session = session
        self.card = card
        self.match = match
        self.agentId = agentId
        self.connection = connection
    }
}

final class Coordinator {
    private var config: Config
    private let registry: SessionRegistry
    private let visibility: Visibility
    private let notifications: SystemNotifications
    private let notch: NotchController?
    private let limits: LimitsStore
    private let indicators: IndicatorsState
    private var pending: [PendingRequest] = []
    private var timer: Timer?
    private var rowsTimer: Timer?
    let system = SystemMonitor()
    private lazy var settings = SettingsWindow(coordinator: self)
    private(set) var claudeEnabled: Bool
    /// Finished turns count as "done" in the compact state for this long.
    private static let doneWindow: TimeInterval = 10 * 60
    private let transcriptQueue = DispatchQueue(label: "notchy.transcripts")

    init(config: Config, notifications: SystemNotifications) {
        self.config = config
        self.registry = SessionRegistry(config: config)
        self.visibility = Visibility(config: config)
        self.notifications = notifications
        self.claudeEnabled = config.claudeModule
        system.alertsEnabled = config.systemAlerts
        self.notch = config.notch ? NotchController(system: system) : nil
        self.limits = LimitsStore(codexPath: config.codexPath, claudePath: config.claudePath)
        self.indicators = IndicatorsState(quietHours: config.quietHours)
        notifications.notchEnabled = config.notch
        // The notch only: clear what earlier runs left in Notification Center.
        if !(config.systemNotifications || !config.notch) { notifications.removeAllDelivered() }

        notifications.onAction = { [weak self] target, action, text in self?.notificationAction(target, action, text) }
        notifications.onOpen = { [weak self] target, action in
            guard let self = self else { return }
            // Clicking a request's notification opens its card in the notch to answer right there.
            // "Open session", informational notifications and requests that are no longer waiting
            // here (answered meanwhile) go to the session.
            if action != "open", let id = target.requestId, let req = self.request(id), let notch = self.notch {
                req.noticed = true
                req.dismissed = false
                self.refreshNotch()
                notch.openRequest(id)
                return
            }
            self.openSession(target)
        }

        if let model = notch?.model {
            model.onDecision = { [weak self] id, decision in self?.resolve(id, decision, via: "notch") }
            model.onOpen = { [weak self] id in
                guard let self = self, let req = self.request(id) else { return }
                req.noticed = true
                Activation.activate(req.session)
            }
            model.onDismiss = { [weak self] id in
                guard let self = self, let req = self.request(id) else { return }
                req.dismissed = true
                self.notifications.remove(requestId: id)
                self.refreshNotch()
            }
            model.onOpenSession = { [weak self] sessionId in
                guard let self = self else { return }
                Activation.activate(self.registry.sessions[sessionId])
            }
            notch?.onNoticed = { [weak self] id in self?.request(id)?.noticed = true }
            model.indicatorsHidden = indicators.hidden
            model.onToggleIndicators = { [weak self] in self?.indicators.apply("toggle") }
            indicators.onChange = { [weak self] hidden in self?.notch?.setIndicatorsHidden(hidden) }
            limits.onChange = { [weak self] snapshot in self?.notch?.setLimits(snapshot) }
            notch?.onShowLimits = { [weak self] in
                guard let self = self, self.claudeEnabled else { return }
                self.limits.refreshSoon()
            }
            model.onOpenSettings = { [weak self] in self?.settings.show() }
            model.claudeEnabled = claudeEnabled
            if claudeEnabled { limits.start() }
        }
        // Relative times ("done 7 min ago") and the compact state's "done" count age without events.
        rowsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.publishSessions() }
    }

    // MARK: Settings

    var currentConfig: Config { config }
    var indicatorsHidden: Bool { indicators.hidden }

    func setClaudeEnabled(_ on: Bool) {
        guard on != claudeEnabled else { return }
        claudeEnabled = on
        config.claudeModule = on
        ConfigFile.set("claude_module", on)
        if on {
            limits.start()
        } else {
            for req in pending { resolve(req.id, .pass, via: "module off") }
            limits.stop()
        }
        notch?.model.claudeEnabled = on
        publishSessions()
        log("[settings] claude module \(on ? "on" : "off")")
    }

    func setSystemAlerts(_ on: Bool) {
        config.systemAlerts = on
        ConfigFile.set("system_alerts", on)
        system.alertsEnabled = on
    }

    func setOpenAtLogin(_ on: Bool) {
        config.openAtLogin = on
        ConfigFile.set("open_at_login", on)
        LoginItem.sync(enabled: on)
    }

    func setIndicatorsHidden(_ hidden: Bool) { indicators.apply(hidden ? "hide" : "show") }

    // MARK: Messages

    func handle(_ json: [String: Any], _ connection: Connection) {
        guard let message = Message(json) else {
            connection.close()
            return
        }
        if message.type != "request" { connection.close() }
        guard claudeEnabled || message.type == "debug" || message.type == "indicators" else {
            // The module is off: the hook falls through to Claude Code's own dialog at once.
            if message.type == "request" { connection.reply(Decision.pass.json) }
            return
        }
        let session = registry.update(message.session)
        if message.type != "debug" && message.type != "indicators" { limits.claudeActive() }
        defer { publishSessions() }

        switch message.type {
        case "session":
            guard let s = session else { return }
            switch message.event {
            case "UserPromptSubmit":
                s.turnStart = Date()
                s.lastTool = ""
                release(sessionId: s.id, mainOnly: true, reason: "new prompt")
                notifications.removeAll(sessionId: s.id)
            case "SessionEnd":
                release(sessionId: s.id, reason: "session ended")
                registry.remove(s.id)
            default:
                break
            }
        case "request":
            handleRequest(message, session, connection)
        case "resolve":
            if let s = session {
                s.lastTool = message.tool
                release(sessionId: s.id, match: message.match, reason: "\(message.tool) finished")
            }
        case "notify":
            if let s = session, let card = message.card { handleNotify(card, s) }
        case "indicators":
            indicators.apply(json.str("command"))
        case "debug":
            // Dev-only stand-in for a click, so the whole chain can be tested without a mouse.
            guard Visibility.forceOffscreen else { return }
            let shot = json.str("snapshot")
            if !shot.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.notch?.snapshot(to: shot) }
            }
            switch json.str("expand") {
            case "alert":   // stand-in for a real alert in screenshots
                notch?.model.systemAlert = .cpu(0.93, "Xcode")
                notch?.setExpanded(nil)
                return
            case "request": notch?.setExpanded(.request); return
            case "panel", "limits":
                if let t = PanelTab(rawValue: json.str("tab")) { notch?.model.tab = t }
                notch?.setExpanded(.panel)
                return
            case "none": notch?.setExpanded(nil); return
            default: break
            }
            guard let first = pending.first, let d = json["decision"] as? [String: Any] else { return }
            switch d.str("decision") {
            case "answer": resolve(first.id, .answer(d["answers"] as? [String: String] ?? [:]), via: "debug")
            case "allow": resolve(first.id, .allow, via: "debug")
            case "deny": resolve(first.id, .deny(d.str("message")), via: "debug")
            default: resolve(first.id, .pass, via: "debug")
            }
        default:
            log("[msg] unknown type \(message.type)")
        }
    }

    private func handleRequest(_ message: Message, _ session: SessionState?, _ connection: Connection) {
        guard let s = session, let card = message.card, config.enabled(card.kind) else {
            connection.reply(Decision.pass.json)
            return
        }
        let req = PendingRequest(id: message.id, session: s, card: card, match: message.match,
                                 agentId: message.session.str("agentId"), connection: connection)
        pending.append(req)
        connection.whenPeerCloses { [weak self] in self?.dropped(req.id) }
        log("[request] \(s.project) | \(card.kind.rawValue) \(card.tool) | \(req.id.prefix(8))")
        evaluate()
        startTimer()
    }

    private func handleNotify(_ card: Card, _ s: SessionState) {
        switch card.kind {
        case .done:
            release(sessionId: s.id, mainOnly: true, reason: "turn ended")
            let start = s.turnStart
            s.turnStart = nil
            if start != nil { s.doneAt = Date() }
            guard config.enabled(.done), card.background == 0, let started = start else { return }
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed >= config.doneMinTurnSeconds else { return }
            guard !visibility.isVisible(s) else {
                log("[done] \(s.project) visible, skipped")
                return
            }
            let subtitle = L.t("Done · \(L.duration(elapsed))", "Готово · \(L.duration(elapsed))")
            announce(card, s, subtitle: subtitle)
            log("[done] \(s.project) after \(Int(elapsed)) s")
        case .error:
            release(sessionId: s.id, mainOnly: true, reason: "turn failed")
            s.turnStart = nil
            s.doneAt = Date()
            guard config.enabled(.error), !visibility.isVisible(s) else { return }
            announce(card, s, subtitle: Texts.kindLabel(card))
        case .attention:
            // Our own card already covers a pending permission of this session.
            guard config.enabled(.attention), !pending.contains(where: { $0.session.id == s.id }),
                  !visibility.isVisible(s) else { return }
            announce(card, s, subtitle: Texts.kindLabel(card))
        default:
            break
        }
    }

    /// Native notifications are used only when asked for (`system_notifications`) or when there is
    /// no notch to show anything in.
    private var useSystemNotifications: Bool { config.systemNotifications || notch == nil }

    /// Done / error / attention: a short banner from the notch. With system notifications on, also a
    /// notification when the user is away (so it waits in Notification Center) or the notch is busy.
    private func announce(_ card: Card, _ s: SessionState, subtitle: String) {
        let sound = config.sound(card.kind)
        if let notch = notch, pending.filter({ $0.presented }).isEmpty {
            notch.showInfo(NotchInfo(sessionId: s.id, headline: s.headline, subtitle: subtitle,
                                     text: Texts.body(card), kind: card.kind), seconds: 8)
            NSSound(named: NSSound.Name(sound))?.play()
            if useSystemNotifications && visibility.userIsAway {
                notifications.postInfo(session: s, card: card, subtitle: subtitle, sound: "none")
            }
        } else if useSystemNotifications {
            notifications.postInfo(session: s, card: card, subtitle: subtitle, sound: sound)
        } else {
            log("[\(card.kind.rawValue)] \(s.project) skipped: the notch is busy with a request")
        }
    }

    // MARK: Presenting

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.evaluate() }
    }

    /// Show requests of off-screen sessions, hide those the user is looking at, post fallbacks.
    private func evaluate() {
        let now = Date()
        var newlyPresented: PendingRequest?

        for req in pending {
            if visibility.isVisible(req.session) {
                if req.presented { log("[present] \(req.session.project) visible again") }
                req.presented = false
                req.fallbackAt = nil
                if req.fallbackPosted {
                    notifications.remove(requestId: req.id)
                    req.fallbackPosted = false
                }
                continue
            }
            guard !req.dismissed else { continue }

            if !req.presented {
                req.presented = true
                req.fallbackAt = useSystemNotifications
                    ? now.addingTimeInterval(notch == nil ? 0 : config.notchFallbackSeconds) : nil
                // The banner drops once; after a look at the session the rim dot is reminder enough.
                if notch != nil && !req.announced {
                    req.announced = true
                    newlyPresented = req
                    if !req.soundPlayed {
                        NSSound(named: NSSound.Name(config.sound(req.card.kind)))?.play()
                        req.soundPlayed = true
                    }
                }
            }
            if let at = req.fallbackAt, now >= at, !req.fallbackPosted, !req.noticed {
                req.fallbackPosted = true
                notifications.postRequest(id: req.id, session: req.session, card: req.card, sound: config.sound(req.card.kind))
                log("[fallback] \(req.session.project) | \(req.card.kind.rawValue)")
            }
        }

        checkTranscripts(now)
        refreshNotch()
        // The card the user may be reading stays; a new one waits in the queue.
        if let req = newlyPresented { notch?.present(req.id) }
        if pending.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Requests answered in the session itself (allowed, denied, answered there) leave the notch
    /// even when no hook tells us: every few seconds, off the main queue.
    private func checkTranscripts(_ now: Date) {
        for req in pending where !req.checking && now.timeIntervalSince(req.createdAt) >= 3
            && now.timeIntervalSince(req.checkedAt) >= 3 && !req.session.transcript.isEmpty {
            req.checking = true
            req.checkedAt = now
            let path = TranscriptCheck.path(transcript: req.session.transcript, agentId: req.agentId)
            let match = req.match, id = req.id
            transcriptQueue.async { [weak self] in
                let answered = TranscriptCheck.answered(path: path, match: match)
                DispatchQueue.main.async {
                    guard let self = self, let req = self.request(id) else { return }
                    req.checking = false
                    if answered == true {
                        log("[release] \(req.session.project) | \(req.card.kind.rawValue) | answered in the session")
                        self.resolve(id, .pass, via: "transcript")
                    }
                }
            }
        }
    }

    /// The Claude widget's list and the compact state's counts.
    private func publishSessions() {
        guard let model = notch?.model else { return }
        let now = Date()
        var rows: [ClaudeSessionRow] = []
        var activity = ClaudeActivity()
        if claudeEnabled {
            let waiting = Dictionary(pending.filter { !$0.dismissed }.map { ($0.session.id, $0.card.kind) },
                                     uniquingKeysWith: { first, _ in first })
            for s in registry.sessions.values {
                let name = s.project.isEmpty ? "Claude Code" : s.project
                if let kind = waiting[s.id] {
                    rows.append(ClaudeSessionRow(id: s.id, name: name, state: .waiting(kind)))
                    activity.waiting += 1
                } else if let start = s.turnStart {
                    rows.append(ClaudeSessionRow(id: s.id, name: name, state: .working(since: start, tool: s.lastTool)))
                    activity.working += 1
                } else if let done = s.doneAt, now.timeIntervalSince(done) < 6 * 3600 {
                    rows.append(ClaudeSessionRow(id: s.id, name: name, state: .done(at: done)))
                    if now.timeIntervalSince(done) < Coordinator.doneWindow { activity.done += 1 }
                }
            }
            func rank(_ r: ClaudeSessionRow) -> (Int, Date) {
                switch r.state {
                case .waiting: return (0, .distantFuture)
                case .working(let since, _): return (1, since)
                case .done(let at): return (2, at)
                }
            }
            rows.sort { a, b in
                let (ra, da) = rank(a), (rb, db) = rank(b)
                return ra != rb ? ra < rb : da > db
            }
        }
        if model.sessions != rows { model.sessions = rows }
        if model.activity != activity { withAnimation(NotchMotion.spring) { model.activity = activity } }
    }

    private func refreshNotch() {
        publishSessions()
        guard let notch = notch else { return }
        // Every waiting request is reachable by pointing at the notch; those announced once keep
        // the rim dot until answered, so a card never vanishes just because its app came to front.
        let shown = pending.filter { !$0.dismissed }
        notch.setItems(shown.map { NotchItem(id: $0.id, sessionId: $0.session.id, headline: $0.session.headline,
                                             card: $0.card, announced: $0.announced) })
    }

    // MARK: Resolving

    private func request(_ id: String) -> PendingRequest? { pending.first { $0.id == id } }

    func resolve(_ id: String, _ decision: Decision, via: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let req = pending.remove(at: index)
        req.connection.reply(decision.json)
        notifications.remove(requestId: req.id)
        refreshNotch()
        // A notification click made us the active app; hand focus back to where the user was.
        if NSApp.isActive { NSApp.hide(nil) }
        log("[resolve] \(req.session.project) | \(req.card.kind.rawValue) | \(decision.json["decision"] ?? "") via \(via) | \(req.id.prefix(8))")
    }

    /// The session moved on without us: let the waiting hooks go. `mainOnly` spares requests of
    /// background subagents, which keep waiting after the main turn has ended.
    private func release(sessionId: String, match: String? = nil, mainOnly: Bool = false, reason: String) {
        for req in pending where req.session.id == sessionId
            && (match == nil || req.match == match || req.match.isEmpty)
            && (!mainOnly || req.agentId.isEmpty) {
            log("[release] \(req.session.project) | \(req.card.kind.rawValue) | \(reason)")
            resolve(req.id, .pass, via: "release")
        }
    }

    /// The hook process went away (timeout, Claude exited).
    private func dropped(_ id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let req = pending.remove(at: index)
        notifications.remove(requestId: id)
        refreshNotch()
        log("[dropped] \(req.session.project) | \(req.card.kind.rawValue)")
    }

    /// The session's app and folder: from the registry, or from the notification itself when this
    /// run doesn't know the session yet.
    private func openSession(_ target: NotificationTarget) {
        if let s = registry.sessions[target.sessionId] {
            Activation.activate(s)
        } else if !target.bundleId.isEmpty {
            let isWorkspace = target.path.hasSuffix(".code-workspace")
            Activation.activate(Activation.Target(sessionId: target.sessionId, bundleId: target.bundleId,
                                                  workspaces: isWorkspace ? [target.path] : [],
                                                  folders: isWorkspace || target.path.isEmpty ? [] : [target.path],
                                                  inExtension: target.entrypoint == "claude-vscode"))
        } else {
            log("[click] session \(target.sessionId.prefix(8)) unknown")
        }
    }

    private func notificationAction(_ target: NotificationTarget, _ action: String, _ text: String?) {
        // Answered meanwhile, or asked before a restart: the session's own dialog is the place now.
        guard let id = target.requestId, let req = request(id) else {
            log("[nc] \(action) for a request no longer waiting here, opening its session")
            openSession(target)
            return
        }
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch action {
        case let a where a.hasPrefix("opt:"):
            guard let q = req.card.questions.first, let i = Int(a.dropFirst(4)), i < q.options.count else { return }
            resolve(id, .answer([q.question: q.options[i].label]), via: "notification")
        case "text":
            guard let q = req.card.questions.first, !typed.isEmpty else { return }
            resolve(id, .answer([q.question: typed]), via: "notification")
        case "approve", "allow":
            resolve(id, .allow, via: "notification")
        case "revise":
            resolve(id, .deny(typed.isEmpty ? L.t("Keep planning.", "Доработай план.") : typed), via: "notification")
        case "deny":
            resolve(id, .deny(L.t("The user denied this action.", "Пользователь запретил это действие.")), via: "notification")
        case "notch":
            req.noticed = true
            req.dismissed = false
            refreshNotch()
            notch?.openRequest(id)
        default:
            break
        }
    }
}
