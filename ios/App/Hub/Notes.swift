import EventKit
import Foundation
import HubKit

// The watch's Notes app (the chats app in notes mode, cmf-watch-sdk sdk/examples/notes; hosts/inboxhost.py is the
// reference): CMFX's own notes (a JSON file in Application Support; no iCloud, a sideloaded app has no
// entitlement for it) and Apple Reminders (EventKit). The watch's buttons: + starts a note (what is typed first is
// its title), the ticked box a to-do list (a new Reminders list, its title typed first; what follows its to-dos),
// the clock a reminder (into the default list; a time said in it, "at 5pm", "tomorrow 9am", sets its alert);
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
    /// The watch's buttons: + New note, a new to-do list, a reminder.
    static let new: UInt8 = 1, newList: UInt8 = 2, newReminder: UInt8 = 3
    /// Recently completed reminders shown under a list's open ones.
    static let done = 3

    let store = NoteStore()
    private(set) var access = EKEventStore.authorizationStatus(for: .reminder)
    var status: String?
    var allowed: Bool { access == .fullAccess }

    private var events = EKEventStore()
    private var ids = ChatsProto.Ids(first: 4)
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
        case .ready:
            tab = 0
            await sendList(quick: true)
        case .open(let id): await show(id)
        case .tap(let idx): await tap(idx)
        case .credit, .stop, .react, .replyTo, .delete: break
        case .remove(let id): await remove(id)
        case .filter(let t):
            tab = min(max(t, 0), 2)
            await sendList()
        case .send(let id, let text): await send(id, text)
        }
    }

    /// A row held and its deletion confirmed on the watch: a note, a to-do list (with its reminders), a reminder.
    private func remove(_ id: UInt8) async {
        switch item(id) {
        case .note(let n): store.delete(n.id)
        case .list(let cal): try? events.removeCalendar(cal, commit: true)
        case .rem(let r): try? events.remove(r, commit: true)
        default: break
        }
        if open == id { open = nil }
        await sendList()
    }

    private enum Item { case new, newList, reminder, list(EKCalendar), note(Note), rem(EKReminder) }

    /// The watch's tab: 0 notes, 1 to-do lists, 2 reminders (each with its own + ).
    private var tab = 0

    private func item(_ id: UInt8) -> Item? {
        if id == Self.new { return .new }
        if id == Self.newList { return .newList }
        if id == Self.newReminder { return .reminder }
        guard let key = ids.key(id) else { return nil }
        if key.hasPrefix("rem:") {
            return (events.calendarItem(withIdentifier: String(key.dropFirst(4))) as? EKReminder).map(Item.rem)
        }
        if key.hasPrefix("list:") {
            return events.calendar(withIdentifier: String(key.dropFirst(5))).map(Item.list)
        }
        return UUID(uuidString: String(key.dropFirst(5))).flatMap(store.note).map(Item.note)
    }

    private var lists: [EKCalendar] {
        allowed ? events.calendars(for: .reminder).sorted { $0.title < $1.title } : []
    }

    private func sendList(quick: Bool = false) async {
        // the tab's own +, then its rows: notes, to-do lists, or reminders by when they are due
        let (newID, newName) = [(Self.new, "New note"), (Self.newList, "New to-do list"), (Self.newReminder, "Reminder")][tab]
        var new = ChatsProto.Row(id: newID, name: newName, preview: "")
        new.isNew = true
        var rows = [new]
        let todo = allowed && tab > 0
            ? await fetch(events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) : []
        switch tab {
        case 0:
            for n in store.notes {
                rows.append(.init(id: ids.id("note:" + n.id.uuidString), name: n.title.isEmpty ? "Untitled" : n.title,
                                  preview: n.lines.first { !$0.isEmpty } ?? "No text yet"))
            }
        case 1:
            for cal in lists {
                let n = todo.filter { $0.calendar?.calendarIdentifier == cal.calendarIdentifier }.count
                rows.append(.init(id: ids.id("list:" + cal.calendarIdentifier), name: cal.title, preview: "\(n) to do"))
            }
        default:
            let due = todo.compactMap { r in Self.due(r).map { (r, $0) } }.sorted { $0.1 < $1.1 }
            for (r, d) in due.prefix(ChatsProto.maxRows - 1) {
                rows.append(.init(id: ids.id("rem:" + r.calendarItemIdentifier), unread: d < .now, name: r.title ?? "Reminder",
                                  preview: Self.dueText(d) + " · " + (r.calendar?.title ?? "")))
            }
            if due.isEmpty, !allowed {
                rows.append(.init(id: Self.newReminder, name: "Reminders", preview: "Allow them in CMFX on the iPhone"))
            }
        }
        await out(ChatsProto.list(rows) + (quick ? ChatsProto.quick(Self.quick) : []))
    }

    /// Opens id on the watch: a note's lines, or a list's reminders to do then a few done.
    private func show(_ id: UInt8) async {
        open = id
        shown = []
        switch item(id) {
        case .new: await out([ChatsProto.open(id, title: "New note")])
        case .newList:
            await out([ChatsProto.open(id, title: "New to-do list"),
                       ChatsProto.message(0, allowed ? "Type its name, then the to-dos" : "Allow Reminders in CMFX on the iPhone")])
        case .reminder:
            await out([ChatsProto.open(id, title: "Reminder"),
                       ChatsProto.message(0, allowed ? "What, and when: \"Call mum at 5pm\"" : "Allow Reminders in CMFX on the iPhone")])
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
        case .rem(let r):
            // the reminder to tick, and when
            shown = [r]
            let at = Self.due(r).map { "Due " + Self.dueText($0) } ?? "No time"
            await out(ChatsProto.chat(id, title: r.title ?? "Reminder",
                                      [(false, kind(r), r.title ?? ""), (false, ChatsProto.plain, at + " · " + (r.calendar?.title ?? ""))]))
        case nil: await out([ChatsProto.open(id, title: "Gone")])
        }
    }

    /// When a reminder is due (its components may come without a calendar).
    static func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }

    /// "Today 17:00", "Tomorrow 9:00", "Fri 15:00", "3 Dec 10:00".
    static func dueText(_ d: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return "Today " + time }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow " + time }
        if d > now, d.timeIntervalSince(now) < 6 * 86400 { return d.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
        return d.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }

    private func kind(_ r: EKReminder) -> UInt8 { r.isCompleted ? ChatsProto.done : ChatsProto.todo }

    /// A tap on a reminder ticks it (or unticks it); on a note, nothing.
    private func tap(_ idx: Int) async {
        guard let open, idx < shown.count else { return }
        switch item(open) {
        case .list, .rem: break
        default: return
        }
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
        case .newList:
            guard action == nil, allowed else { return }
            // a Reminders list of its own: the to-dos typed next go in it
            let cal = EKCalendar(for: .reminder, eventStore: events)
            cal.title = text
            cal.source = events.defaultCalendarForNewReminders()?.source
                ?? events.sources.first { $0.sourceType == .local || $0.sourceType == .calDAV }
            do {
                try events.saveCalendar(cal, commit: true)
            } catch {
                status = error.localizedDescription
                return await out([ChatsProto.append("Not made: \(error.localizedDescription)")])
            }
            let lid = ids.id("list:" + cal.calendarIdentifier)
            open = lid
            shown = []
            await out([ChatsProto.open(lid, title: cal.title)])
        case .reminder:
            guard action == nil, allowed else { return }
            let r = EKReminder(eventStore: events)
            let (what, when) = Self.when(text)
            r.title = what
            r.calendar = events.defaultCalendarForNewReminders()
            if let when {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
                r.addAlarm(EKAlarm(absoluteDate: when))
            }
            do {
                try events.save(r, commit: true)
            } catch {
                status = error.localizedDescription
                return await out([ChatsProto.append("Not added: \(error.localizedDescription)")])
            }
            let at = when.map { " · " + $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? ""
            await out([ChatsProto.append(kind: ChatsProto.todo, what + at)])
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
        case .rem, nil: return
        }
        await sendList()
    }

    /// A reminder's words and the time said in them: "Call mum at 5pm" → ("Call mum", today 17:00); a time
    /// already past today is tomorrow's.
    static func when(_ text: String, now: Date = .now) -> (String, Date?) {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = d.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), var date = m.date,
              let r = Range(m.range, in: text) else { return (text, nil) }
        if date < now, date.timeIntervalSince(now) > -86400 {
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        }
        var what = text.replacingCharacters(in: r, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        for tail in [" at", " on", " by"] where what.lowercased().hasSuffix(tail) { what = String(what.dropLast(tail.count)) }
        return (what.isEmpty ? text : what, date)
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
