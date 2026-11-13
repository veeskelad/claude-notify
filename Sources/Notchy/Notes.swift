import AppKit
import SwiftUI

// A note and a task list in the panel. One file, ~/Library/Application Support/Notchy/notes.json,
// written by the panel and by Claude Code sessions (plugin/skills/notchy-notes/notes.py), which
// pings the socket ({"type":"notes"}) after a change so the panel reloads.
//
//   {"note": "…", "tasks": [{"id": "…", "text": "…", "done": false, "by": "user" | "claude", "created": 1794550000}]}

struct NoteTask: Identifiable, Equatable {
    var id: String
    var text: String
    var done: Bool
    var by: String          // "user" or "claude"
    var created: Double
}

final class NotesStore: ObservableObject {
    @Published var note = "" { didSet { if note != oldValue && !loading { scheduleSave() } } }
    @Published private(set) var tasks: [NoteTask] = []

    static let file = "\(Paths.supportDir)/notes.json"
    private var loading = false
    private var saveWork: DispatchWorkItem?
    private var mtime: Date?

    init() { reload() }

    /// Re-read the file if it changed (a Claude session wrote to it, or another copy of the panel).
    func reload() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: NotesStore.file)
        let m = attrs?[.modificationDate] as? Date
        guard m == nil || m != mtime else { return }
        mtime = m
        guard let data = FileManager.default.contents(atPath: NotesStore.file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        loading = true
        defer { loading = false }
        let text = json["note"] as? String ?? ""
        if text != note { note = text }
        let list = (json["tasks"] as? [[String: Any]] ?? []).compactMap { t -> NoteTask? in
            guard let text = t["text"] as? String, !text.isEmpty else { return nil }
            return NoteTask(id: t["id"] as? String ?? UUID().uuidString, text: text, done: t["done"] as? Bool ?? false,
                            by: t["by"] as? String ?? "user", created: (t["created"] as? NSNumber)?.doubleValue ?? 0)
        }
        if list != tasks { tasks = list }
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        tasks.insert(NoteTask(id: UUID().uuidString, text: t, done: false, by: "user", created: Date().timeIntervalSince1970), at: 0)
        save()
    }

    func toggle(_ id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done.toggle()
        save()
    }

    func remove(_ id: String) {
        tasks.removeAll { $0.id == id }
        save()
    }

    func clearDone() {
        tasks.removeAll(where: \.done)
        save()
    }

    var openCount: Int { tasks.filter { !$0.done }.count }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func save() {
        saveWork?.cancel()
        // Pick up what a session wrote meanwhile before overwriting the file.
        let ours = (note, tasks)
        mtime = nil
        let json: [String: Any] = [
            "note": ours.0,
            "tasks": ours.1.map { ["id": $0.id, "text": $0.text, "done": $0.done, "by": $0.by, "created": $0.created] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        do {
            try data.write(to: URL(fileURLWithPath: NotesStore.file), options: .atomic)
            mtime = (try? FileManager.default.attributesOfItem(atPath: NotesStore.file))?[.modificationDate] as? Date
        } catch {
            log("[notes] save failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - View

struct NotesTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var notes: NotesStore
    @State private var newTask = ""
    @FocusState private var focus: Field?
    private enum Field { case note, task }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L.t("Note", "Заметка")).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                    Spacer()
                    Button(L.t("To Notes", "В Заметки")) { AppleNotes.save(notes.note) { model.onSavedToNotes($0) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                        .disabled(notes.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(L.t("Create a note in the Notes app with this text", "Создать заметку с этим текстом в приложении «Заметки»"))
                    Button(L.t("Copy", "Скопировать")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes.note, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                    .disabled(notes.note.isEmpty)
                }
                TextEditor(text: $notes.note)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .note)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, 2).padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L.t("Tasks · \(notes.openCount)", "Задачи · \(notes.openCount)"))
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                    Spacer()
                    if notes.tasks.contains(where: \.done) {
                        Button(L.t("Clear done", "Убрать готовые")) { notes.clearDone() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.4))
                    TextField(L.t("New task", "Новая задача"), text: $newTask)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focus, equals: .task)
                        .onSubmit {
                            notes.add(newTask)
                            newTask = ""
                        }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notes.tasks) { task in
                            TaskRow(task: task, toggle: { notes.toggle(task.id) }, remove: { notes.remove(task.id) })
                        }
                    }
                }
            }
            .frame(width: 236)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(height: 214, alignment: .top)
        .onAppear { notes.reload() }
        // Typing doesn't hold the panel open: the text is saved as you go, so it folds as usual.
        .onChange(of: focus) { f in
            if f != nil { model.onWantsKeyboard() }
        }
    }
}

struct TaskRow: View {
    let task: NoteTask
    let toggle: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(task.done ? .green : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            Text(task.text)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(task.done ? 0.4 : 0.95))
                .strikethrough(task.done, color: .white.opacity(0.4))
                .lineLimit(2)
            Spacer(minLength: 4)
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            } else if task.by == "claude" {
                Image(systemName: "asterisk").font(.system(size: 10, weight: .bold)).foregroundColor(claudeOrange)
                    .help(L.t("Added by Claude", "Добавил Claude"))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The macOS Notes app: a new note in the default folder, first line as its title. The first time
/// macOS asks whether Notchy may control Notes.
enum AppleNotes {
    static func save(_ text: String, done: @escaping (Bool) -> Void) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let html = body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            "<div>" + (line.isEmpty ? "<br>" : escape(String(line))) + "</div>"
        }.joined()
        let script = """
        tell application "Notes"
            make new note at default folder of default account with properties {body:"\(appleScriptString(html))"}
        end tell
        """
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error = error { log("[notes] Apple Notes: \(error[NSAppleScript.errorMessage] ?? error)") }
            done(error == nil)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func appleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
