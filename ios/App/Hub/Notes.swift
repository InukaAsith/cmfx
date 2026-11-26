import EventKit
import Foundation
import HubKit

// The watch's Notes app (the chats app in notes mode, cmf-watch-sdk sdk/examples/notes; hosts/inboxhost.py is the
// reference): CMFX's own notes (a JSON file in Application Support; no iCloud, a sideloaded app has no
// entitlement for it) and Apple Reminders (EventKit). Row 0 starts a note (what is typed first is its title);
// each note is a row, shown as a page of lines; each reminder list is a row whose reminders tick with a tap.
// Typing adds a line or a reminder; the watch shows nothing typed until the phone sends it back (`A`).

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var lines: [String]
    var modified = Date.now
}

/// The notes, newest first, saved on each change.
@MainActor @Observable final class NoteStore {
    private(set) var notes: [Note] = []
    /// After a change (the watch gets the list again).
    @ObservationIgnored var changed: (() -> Void)?

    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "notes.json")
    }

    init() {
        notes = (try? JSONDecoder().decode([Note].self, from: Data(contentsOf: Self.url))) ?? []
        notes.sort { $0.modified > $1.modified }
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    @discardableResult
    func add(title: String, lines: [String] = []) -> Note {
        let n = Note(title: title, lines: lines)
        notes.insert(n, at: 0)
        save()
        return n
    }

    func update(_ n: Note) {
        guard let i = notes.firstIndex(where: { $0.id == n.id }), notes[i] != n else { return }
        var n = n
        n.modified = .now
        notes.remove(at: i)
        notes.insert(n, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(notes).write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        changed?()
    }
}

@MainActor @Observable final class NotesService: WatchService {
    static let app = "Notes"
    static let quick = ["• Delete note", "• Clear done", "Buy", "Call", "Remember to"]
    /// Row 0: + New note.
    static let new: UInt8 = 1
    /// Recently completed reminders shown under a list's open ones.
    static let done = 3

    let store = NoteStore()
    private(set) var access = EKEventStore.authorizationStatus(for: .reminder)
    var status: String?
    var allowed: Bool { access == .fullAccess }

    private var events = EKEventStore()
    private var ids = ChatsProto.Ids(first: 2)
    /// The open chat, and the reminders it shows by message idx.
    private var open: UInt8?
    private var shown: [EKReminder] = []
    /// The watch app is open: it talked, and the last message to it went through.
    private var live = false
    private var chain: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    init() {
        store.changed = { [weak self] in self?.changed() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    func requestAccess() async {
        do { _ = try await events.requestFullAccessToReminders() } catch { status = error.localizedDescription }
        events = EKEventStore() // a store made before the grant sees no lists
        access = EKEventStore.authorizationStatus(for: .reminder)
        changed()
    }

    /// Something changed on the phone: the list again while the watch app is open (once for a burst).
    private func changed() {
        guard live else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            enqueue { await self.sendList() }
        }
    }

    // MARK: watch

    func receive(_ m: Data) {
        guard let ask = ChatsProto.parse(m) else { return }
        live = true
        enqueue { await self.handle(ask) }
    }

    /// One job at a time: a chat's H and M messages must not interleave with another's.
    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { await prev?.value; await job() }
    }

    private func handle(_ ask: ChatsProto.Ask) async {
        switch ask {
        case .ready: await sendList(quick: true)
        case .open(let id): await show(id)
        case .tap(let idx): await tap(idx)
        case .send(let id, let text): await send(id, text)
        }
    }

    private enum Item { case new, list(EKCalendar), note(Note) }

    private func item(_ id: UInt8) -> Item? {
        if id == Self.new { return .new }
        guard let key = ids.key(id) else { return nil }
        if key.hasPrefix("list:") {
            return events.calendar(withIdentifier: String(key.dropFirst(5))).map(Item.list)
        }
        return UUID(uuidString: String(key.dropFirst(5))).flatMap(store.note).map(Item.note)
    }

    private var lists: [EKCalendar] {
        allowed ? events.calendars(for: .reminder).sorted { $0.title < $1.title } : []
    }

    private func sendList(quick: Bool = false) async {
        var new = ChatsProto.Row(id: Self.new, name: "New note", preview: "Write one on the watch")
        new.isNew = true // the watch's + button
        var rows = [new]
        for n in store.notes {
            rows.append(.init(id: ids.id("note:" + n.id.uuidString), name: n.title.isEmpty ? "Untitled" : n.title,
                              preview: n.lines.first { !$0.isEmpty } ?? "No text yet"))
        }
        let todo = allowed ? await fetch(events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) : []
        for cal in lists {
            let n = todo.filter { $0.calendar?.calendarIdentifier == cal.calendarIdentifier }.count
            rows.append(.init(id: ids.id("list:" + cal.calendarIdentifier), name: cal.title, preview: "\(n) to do"))
        }
        await out(ChatsProto.list(rows) + (quick ? ChatsProto.quick(Self.quick) : []))
    }

    /// Opens id on the watch: a note's lines, or a list's reminders to do then a few done.
    private func show(_ id: UInt8) async {
        open = id
        shown = []
        switch item(id) {
        case .new: await out([ChatsProto.open(id, title: "New note")])
        case .note(let n):
            await out(ChatsProto.chat(id, title: n.title, n.lines.flatMap { ChatsProto.page($0) }.map { (false, ChatsProto.plain, $0) }))
        case .list(let cal):
            let todo = await fetch(events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [cal]))
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            let done = await fetch(events.predicateForCompletedReminders(withCompletionDateStarting: .now.addingTimeInterval(-7 * 86400),
                                                                         ending: nil, calendars: [cal]))
                .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
            shown = Array(todo.prefix(ChatsProto.maxMsgs))
            shown += done.prefix(min(Self.done, ChatsProto.maxMsgs - shown.count))
            await out(ChatsProto.chat(id, title: cal.title, shown.map { (false, kind($0), $0.title ?? "") }))
        case nil: await out([ChatsProto.open(id, title: "Gone")])
        }
    }

    private func kind(_ r: EKReminder) -> UInt8 { r.isCompleted ? ChatsProto.done : ChatsProto.todo }

    /// A tap on a reminder ticks it (or unticks it); on a note, nothing.
    private func tap(_ idx: Int) async {
        guard let open, case .list = item(open), idx < shown.count else { return }
        let r = shown[idx]
        r.isCompleted.toggle()
        do {
            try events.save(r, commit: true)
        } catch {
            r.isCompleted.toggle()
            status = error.localizedDescription
        }
        await out([ChatsProto.message(idx, kind: kind(r), r.title ?? "")])
    }

    /// Text from the watch: a new note's title, a line, a reminder, or an action ("• Delete note", "• Clear done").
    /// What is kept goes back as `A` (the watch shows nothing typed by itself).
    private func send(_ id: UInt8, _ text: String) async {
        let action = ChatsProto.action(text)
        switch item(id) {
        case .new:
            guard action == nil else { return }
            let n = store.add(title: text)
            let nid = ids.id("note:" + n.id.uuidString)
            open = nid
            shown = []
            await out([ChatsProto.open(nid, title: n.title)])
        case .note(var n):
            switch action {
            case "Delete note":
                store.delete(n.id)
                await out([ChatsProto.open(id, title: n.title), ChatsProto.append("Deleted")])
            case nil:
                n.lines.append(text)
                store.update(n)
                await out(ChatsProto.page(text).map { ChatsProto.append(kind: ChatsProto.plain, $0) })
            default: return
            }
        case .list(let cal):
            switch action {
            case "Clear done":
                do {
                    let done = await fetch(events.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: [cal]))
                    for r in done { try events.remove(r, commit: false) }
                    try events.commit()
                } catch {
                    status = error.localizedDescription
                }
                await show(id)
            case nil:
                let r = EKReminder(eventStore: events)
                r.title = text
                r.calendar = cal
                do {
                    try events.save(r, commit: true)
                } catch {
                    status = error.localizedDescription
                    return await out([ChatsProto.append("Not added: \(error.localizedDescription)")])
                }
                if shown.count < ChatsProto.maxMsgs {
                    // the watch puts it at the end: the same idx for a tap
                    shown.append(r)
                    await out([ChatsProto.append(kind: ChatsProto.todo, text)])
                } else {
                    await show(id)
                }
            default: return
            }
        case nil: return
        }
        await sendList()
    }

    // MARK: phone

    private func fetch(_ p: NSPredicate) async -> [EKReminder] {
        let store = events
        return await withCheckedContinuation { c in
            store.fetchReminders(matching: p) {
                nonisolated(unsafe) let r = $0 ?? []
                c.resume(returning: r)
            }
        }
    }

    private func out(_ msgs: [Data]) async {
        do {
            try await Hub.shared.send(Self.app, msgs)
        } catch {
            live = false
        }
    }
}
