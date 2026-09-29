import AppKit
import UserNotifications

// Native notifications: informational ones (done / attention / error) and the
// fallback for requests nobody reacted to in the notch. Each request gets its
// own category so its answer options show up as actions.

/// Where a notification leads. It carries the session's app and folder, so a click still finds the
/// session after the app restarted and forgot it.
struct NotificationTarget {
    let sessionId: String
    let requestId: String?
    let bundleId: String
    let path: String
}

final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var categories: [String: UNNotificationCategory] = [:]
    /// Requests removed while their notification was still being registered (main queue only).
    private var withdrawn = Set<String>()
    /// Without the notch there is nowhere to "answer in the notch".
    var notchEnabled = true

    /// target, action identifier ("opt:N", "text", "approve", "revise", "allow", "deny", "notch"), typed text
    var onAction: ((NotificationTarget, String, String?) -> Void)?
    /// target (requestId nil for informational notifications), action ("open" or the default click)
    var onOpen: ((NotificationTarget, String) -> Void)?

    func setup(_ completion: @escaping (Bool) -> Void) {
        center.delegate = self
        // Requests of a previous run went with it; hooks still waiting send theirs again.
        center.getDeliveredNotifications { [center] delivered in
            let stale = delivered.filter { $0.request.content.userInfo["requestId"] != nil }.map { $0.request.identifier }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error { log("[nc] authorization error: \(error.localizedDescription)") }
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: Posting

    func postInfo(session: SessionState, card: Card, subtitle: String, sound: String) {
        let content = makeContent(session: session, subtitle: subtitle, body: Texts.body(card), sound: sound)
        add(identifier: "info-\(UUID().uuidString)", content: content)
    }

    func postRequest(id: String, session: SessionState, card: Card, sound: String) {
        let content = makeContent(session: session, subtitle: Texts.kindLabel(card), body: Texts.body(card), sound: sound)
        content.userInfo["requestId"] = id

        let categoryId = "req-\(id)"
        categories[categoryId] = UNNotificationCategory(identifier: categoryId, actions: actions(for: card),
                                                        intentIdentifiers: [], options: [])
        content.categoryIdentifier = categoryId
        center.setNotificationCategories(Set(categories.values))
        withdrawn.remove(id)
        // Categories register asynchronously; reading them back first makes the actions show up reliably.
        center.getNotificationCategories { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !self.withdrawn.contains(id) else { return }
                self.add(identifier: id, content: content)
            }
        }
    }

    private func makeContent(session: SessionState, subtitle: String, body: String, sound: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = session.headline
        content.subtitle = subtitle
        content.body = body
        content.threadIdentifier = session.id
        content.userInfo = ["sessionId": session.id, "bundle": session.hostBundleId ?? "",
                            "path": session.openPath.isEmpty ? session.projectDir : session.openPath]
        switch sound {
        case "none", "": content.sound = nil
        case "default": content.sound = .default
        default: content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
        }
        return content
    }

    private func add(identifier: String, content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error = error { log("[nc] post failed: \(error.localizedDescription)") }
        }
    }

    private func actions(for card: Card) -> [UNNotificationAction] {
        let open = UNNotificationAction(identifier: "open", title: L.t("Open session", "Открыть сессию"), options: [.foreground])
        switch card.kind {
        case .question:
            guard card.fitsNotificationActions, let q = card.questions.first else {
                guard notchEnabled else { return [open] }
                return [UNNotificationAction(identifier: "notch", title: L.t("Answer in the notch", "Ответить в чёлке"), options: []), open]
            }
            var list: [UNNotificationAction] = q.options.enumerated().map {
                UNNotificationAction(identifier: "opt:\($0.offset)", title: $0.element.label, options: [])
            }
            list.append(UNTextInputNotificationAction(identifier: "text", title: L.t("Type an answer…", "Свой ответ…"),
                                                      options: [], textInputButtonTitle: L.t("Send", "Отправить"),
                                                      textInputPlaceholder: ""))
            list.append(open)
            return list
        case .plan:
            return [
                UNNotificationAction(identifier: "approve", title: L.t("Approve", "Одобрить"), options: []),
                UNTextInputNotificationAction(identifier: "revise", title: L.t("Keep planning…", "Доработать…"),
                                              options: [], textInputButtonTitle: L.t("Send", "Отправить"),
                                              textInputPlaceholder: L.t("What to change", "Что изменить")),
                open,
            ]
        case .permission:
            return [
                UNNotificationAction(identifier: "allow", title: L.t("Allow", "Разрешить"), options: []),
                UNNotificationAction(identifier: "deny", title: L.t("Deny", "Запретить"), options: [.destructive]),
                open,
            ]
        default:
            return []
        }
    }

    // MARK: Removing

    func remove(requestId: String) {
        withdrawn.insert(requestId)
        center.removeDeliveredNotifications(withIdentifiers: [requestId])
        center.removePendingNotificationRequests(withIdentifiers: [requestId])
        if categories.removeValue(forKey: "req-\(requestId)") != nil {
            center.setNotificationCategories(Set(categories.values))
        }
    }

    /// The user is back in this session: drop everything it posted.
    func removeAll(sessionId: String) {
        center.getDeliveredNotifications { [center] delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == sessionId }.map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let target = NotificationTarget(sessionId: info["sessionId"] as? String ?? "",
                                        requestId: info["requestId"] as? String,
                                        bundleId: info["bundle"] as? String ?? "",
                                        path: info["path"] as? String ?? "")
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        log("[nc] action=\(action) request=\(target.requestId ?? "-")")

        DispatchQueue.main.async {
            switch action {
            case UNNotificationDefaultActionIdentifier, "open":
                self.onOpen?(target, action)
            case UNNotificationDismissActionIdentifier:
                break
            default:
                if target.requestId != nil { self.onAction?(target, action, text) }
            }
        }
        completionHandler()
    }
}
