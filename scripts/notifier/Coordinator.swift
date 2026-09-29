import AppKit

// Ties hook messages, visibility, the notch and system notifications together.
// Everything here runs on the main queue.
//
// A PermissionRequest hook waits on its socket while Claude Code shows its own
// dialog in parallel; whichever answers first wins. So a pending request is only
// *presented* while its session is off screen, and it is released (reply "pass")
// as soon as the session moves on: tool finished, turn ended, new prompt.

final class PendingRequest {
    let id: String
    let session: SessionState
    let card: Card
    let match: String
    let agentId: String     // set when a subagent asked; the main turn ending doesn't resolve it
    let connection: Connection
    var presented = false
    var soundPlayed = false
    var noticed = false     // the user hovered or clicked it: no fallback notification needed
    var dismissed = false   // the user hid it; the dialog in the session stays
    var fallbackAt: Date?
    var fallbackPosted = false

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
    private let config: Config
    private let registry: SessionRegistry
    private let visibility: Visibility
    private let notifications: SystemNotifications
    private let notch: NotchController?
    private let limits = LimitsStore()
    private var badges: BadgeWatcher?
    private var pending: [PendingRequest] = []
    private var timer: Timer?

    init(config: Config, notifications: SystemNotifications) {
        self.config = config
        self.registry = SessionRegistry(config: config)
        self.visibility = Visibility(config: config)
        self.notifications = notifications
        self.notch = config.notch ? NotchController() : nil
        notifications.notchEnabled = config.notch

        notifications.onAction = { [weak self] id, action, text in self?.notificationAction(id, action, text) }
        notifications.onOpen = { [weak self] sessionId, requestId, action in
            guard let self = self else { return }
            // Clicking a request's notification opens its card in the notch to answer right there;
            // the "Open session" action (and informational notifications) go to the session.
            if action != "open", let id = requestId, let req = self.request(id), let notch = self.notch {
                req.noticed = true
                req.dismissed = false
                self.refreshNotch()
                notch.openRequest(id)
                return
            }
            Activation.activate(self.registry.sessions[sessionId])
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
            limits.onChange = { [weak self] snapshot in self?.notch?.setLimits(snapshot) }
            limits.start()
            if config.badges {
                let watcher = BadgeWatcher(ignore: config.badgesIgnore)
                watcher.onChange = { [weak self] all, grown in self?.badgesChanged(all, grown) }
                watcher.start()
                badges = watcher
            }
        }
    }

    // MARK: Messages

    func handle(_ json: [String: Any], _ connection: Connection) {
        guard let message = Message(json) else {
            connection.close()
            return
        }
        let session = registry.update(message.session)
        if message.type != "request" { connection.close() }

        switch message.type {
        case "session":
            guard let s = session else { return }
            switch message.event {
            case "UserPromptSubmit":
                s.turnStart = Date()
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
            if let s = session { release(sessionId: s.id, match: message.match, reason: "\(message.tool) finished") }
        case "notify":
            if let s = session, let card = message.card { handleNotify(card, s) }
        case "debug":
            // Dev-only stand-in for a click, so the whole chain can be tested without a mouse.
            guard Visibility.forceOffscreen else { return }
            switch json.str("expand") {
            case "request": notch?.setExpanded(.request); return
            case "limits": notch?.setExpanded(.limits); return
            case "none": notch?.setExpanded(nil); return
            default: break
            }
            guard let first = pending.first else { return }
            let d = json["decision"] as? [String: Any] ?? [:]
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

    /// Done / error / attention: a short banner from the notch. A system notification too when the
    /// user is away (so it waits in Notification Center), or when the notch is off or busy with requests.
    private func announce(_ card: Card, _ s: SessionState, subtitle: String) {
        let sound = config.sound(card.kind)
        if let notch = notch, pending.filter({ $0.presented }).isEmpty {
            notch.showInfo(NotchInfo(sessionId: s.id, headline: s.headline, subtitle: subtitle,
                                     text: Texts.body(card), kind: card.kind), seconds: 8)
            NSSound(named: NSSound.Name(sound))?.play()
            if visibility.userIsAway {
                notifications.postInfo(session: s, card: card, subtitle: subtitle, sound: "none")
            }
        } else {
            notifications.postInfo(session: s, card: card, subtitle: subtitle, sound: sound)
        }
    }

    /// Other apps' Dock counters: keep the overview current, announce growth briefly — unless a
    /// Claude request is out (it has priority) or the app is already in front.
    private func badgesChanged(_ all: [AppBadge], _ grown: [AppBadge]) {
        notch?.setBadges(all)
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        guard let badge = grown.first(where: { $0.url?.path != front }),
              pending.filter({ $0.presented }).isEmpty else { return }
        log("[badges] \(badge.name) \(badge.label)")
        notch?.showBadge(badge)
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
                if req.presented { log("[present] \(req.session.project) visible again, hidden") }
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
                req.fallbackAt = now.addingTimeInterval(notch == nil ? 0 : config.notchFallbackSeconds)
                if notch != nil {
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

        refreshNotch()
        // The card the user may be reading stays; a new one waits in the queue.
        if let req = newlyPresented { notch?.present(req.id) }
        if pending.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refreshNotch() {
        guard let notch = notch else { return }
        // Every waiting request is reachable by pointing at the notch; only those of off-screen
        // sessions are announced (banner, then the rim dot).
        let shown = pending.filter { !$0.dismissed }
        notch.setItems(shown.map { NotchItem(id: $0.id, sessionId: $0.session.id, headline: $0.session.headline,
                                             card: $0.card, announced: $0.presented) })
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
        log("[resolve] \(req.session.project) | \(req.card.kind.rawValue) | \(decision.json["decision"] ?? "") via \(via)")
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

    private func notificationAction(_ id: String, _ action: String, _ text: String?) {
        guard let req = request(id) else {
            log("[nc] action for unknown request \(id.prefix(8))")
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
