import AppKit
import Carbon.HIToolbox
import Foundation

/// `fleet --selftest`. The pieces of this app whose rules only ever meet at runtime — whether a
/// sub-agent is still working, which sessions are ghosts — read from files written by something
/// else, so checked against files rather than mocks.
@MainActor
enum SelfCheck {

    static func run() -> Int {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got == want { print("  ok    \(what)") } else {
                print("  FAIL  \(what)\n        want \(want)\n        got  \(got)")
                failures += 1
            }
        }

        subagents(expect)
        cutLine(expect)
        queuedPrompt(expect)
        freshSession(expect)
        heldPrompt(expect)
        ghosts(expect)
        ports(expect)
        reels(expect)
        crons(expect)
        judging(expect)
        repairs(expect)
        money(expect)
        grid(expect)
        reads(expect)
        inbox(expect)

        print(failures == 0 ? "\nall ok" : "\n\(failures) FAILED")
        return failures
    }

    // MARK: - Inbox

    /// The watcher's lines, from files as the checker writes them: in time order, ←→ wrap and take nothing away,
    /// ↵ opens and sets the line aside in `done/` once its terminal has started; ↑ and ↓ only ask, however often,
    /// and only ↵ says yes (↑ to `done/`, ↓ for good).
    private static func inbox(_ expect: (Bool, Bool, String) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fleet-inbox-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (id, at) in [("b", 2), ("a", 1), ("d", 4), ("c", 3)] {
            try? Data(#"{"id":"\#(id)","at":\#(at),"kind":"done","subject":"s","line":"l","dir":"/","options":["--resume","x"]}"#.utf8)
                .write(to: folder.appending(path: "\(id).json"))
        }
        try? Data("{".utf8).write(to: folder.appending(path: ".e"))
        let inbox = Inbox(folder: folder)
        var opened: [String] = [], starts = false
        inbox.launch = { opened.append($0.id); return starts }
        let kept = { (id: String) in FileManager.default.fileExists(atPath: folder.appending(path: "done/\(id).json").path) }
        func press(_ code: Int) { _ = inbox.key(UInt16(code)) }
        inbox.refresh()
        expect(inbox.items.map(\.id) == ["a", "b", "c", "d"], true, "inbox: read in time order, a file not yet renamed in left out")
        press(kVK_LeftArrow)
        expect(inbox.current?.id == "d" && inbox.items.count == 4, true, "inbox: ← from the first wraps to the last, nothing taken")
        press(kVK_Return)
        expect(opened == ["d"] && inbox.items.count == 4, true, "inbox: an open whose terminal did not start keeps its line")
        starts = true
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a", "b", "c"] && kept("d"), true, "inbox: an open that started sets its line aside as done")
        press(kVK_UpArrow)
        expect(inbox.items.count == 3 && inbox.asking == Inbox.Ask(id: "c", trash: false), true, "inbox: ↑ only asks")
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a", "b"] && kept("c") && opened.count == 2, true, "inbox: ↵ after ↑ sets it aside as done, opening nothing")
        press(kVK_DownArrow)
        press(kVK_DownArrow)
        expect(inbox.items.count == 2 && inbox.asking == Inbox.Ask(id: "b", trash: true), true, "inbox: ↓ asks, and ↓ again at once (a double click, a held key) still asks")
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a"] && !kept("b") && opened.count == 2, true, "inbox: ↵ after ↓ removes it for good")
        starts = false
        press(kVK_DownArrow)
        press(kVK_Escape)
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a"] && opened.count == 3, true, "inbox: Esc after ↓ keeps it, and ↵ then opens")
        press(kVK_UpArrow)
        press(kVK_UpArrow)
        press(kVK_DownArrow)
        press(kVK_DownArrow)
        expect(inbox.items.map(\.id) == ["a"] && !kept("a"), true, "inbox: ↑↑ and ↓↓ only ask, however long apart")
        press(kVK_UpArrow)
        press(kVK_Return)
        expect(inbox.items.isEmpty && kept("a"), true, "inbox: only ↵ says yes")
        expect(inbox.key(UInt16(kVK_ANSI_A)), false, "inbox: a letter is left to go on")
        var noon = DateComponents(calendar: .current, year: 2026, month: 10, day: 14, hour: 12)
        let now = noon.date!
        noon.hour = 9; noon.minute = 5
        let morning = noon.date!.timeIntervalSince1970 * 1000
        expect(InboxView.when(morning, now: now) == "09h05" && InboxView.when(morning - 86_400_000, now: now) == "13/10 09h05", true,
               "inbox: today's line by its hour, written 09h05; an older one with its day")

        // The entrance, read at every frame on a panel put off every screen, where nothing of it can be seen.
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let place = NSRect(x: -30000, y: -30000, width: 400, height: 100)
        Inbox.present(panel, at: place)
        var alphas: [CGFloat] = [], ys: [CGFloat] = []
        let end = Date().addingTimeInterval(Inbox.entrance + 0.15)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            alphas.append(panel.alphaValue)
            ys.append(panel.frame.minY)
        }
        panel.orderOut(nil)
        let oneWay = zip(alphas, alphas.dropFirst()).allSatisfy { $0 <= $1 } && zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 }
        print("        entrance: \(Set(alphas).count) alphas, \(Set(ys).count) heights over \(alphas.count) frames")
        expect(oneWay && alphas.last == 1 && ys.last == place.minY && Set(ys).count > 3 && Set(alphas).count > 3, true,
               "inbox: fades in while it rises into its place, in steps, each going one way only")
    }

    // MARK: - Reads

    /// What stands between Fleet and the day's Firestore reads: a run that does not read is
    /// handed the kept copy, a kept copy young enough spares the read, a spent share refuses.
    private static func reads(_ expect: (Bool, Bool, String) -> Void) {
        let real = (Firestore.store, Firestore.reads)
        defer { (Firestore.store, Firestore.reads) = real }
        Firestore.store = FileManager.default.temporaryDirectory.appending(path: "fleet-selftest-\(getpid())")
        try? FileManager.default.removeItem(at: Firestore.store)
        defer { try? FileManager.default.removeItem(at: Firestore.store) }
        func outcome(_ age: TimeInterval) -> String {
            do { return try Firestore.withoutAsking("mail", reusing: age).map { "kept \($0.count)" } ?? "ask" }
            catch { return "\(error)" }
        }

        Firestore.reads = false
        expect(outcome(0) == "unread", true, "reads: a run that does not read, with nothing kept, is refused")
        Firestore.reads = true
        expect(outcome(600) == "ask", true, "reads: with nothing kept, the app asks Firestore")

        // A copy read two hours ago.
        try? FileManager.default.createDirectory(at: Firestore.store, withIntermediateDirectories: true)
        let copy = Firestore.store.appending(path: "mail.json")
        try? Data(#"{"documents":[{"name":"p/mail/a","fields":{}}]}"#.utf8).write(to: copy)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)],
                                               ofItemAtPath: copy.path)
        expect(outcome(6 * 3600) == "kept 1", true, "reads: a copy two hours old spares the six-hourly read")
        expect(outcome(600) == "ask", true, "reads: and is too old for a panel that opens")
        expect(outcome(.infinity) == "kept 1", true, "reads: a restart with the reads refused draws it, however old")
        Firestore.reads = false
        expect(outcome(0) == "kept 1", true, "reads: a render draws the kept copy and never asks")
        Firestore.reads = true

        let stamp = ISO8601DateFormatter()
        expect(Firestore.quotaDay(stamp.date(from: "2026-10-12T06:59:00Z")!) == "2026-10-11"
               && Firestore.quotaDay(stamp.date(from: "2026-10-12T07:00:00Z")!) == "2026-10-12", true,
               "reads: Firestore's day turns at 09:00 in Paris")
        Firestore.spend(Firestore.dailyReads - 1)
        expect(outcome(600) == "ask", true, "reads: one document short of the share, still asking")
        Firestore.spend(1)
        expect(outcome(600) == "budget", true, "reads: the share spent, refused before the network")
        expect(Firestore.spent(Date().addingTimeInterval(86_400)) == 0, true, "reads: and a new day starts at nothing")

        // The stamp: one read that says whether the kept copy still stands.
        let hourAgo = Date().addingTimeInterval(-3600)
        expect(Firestore.stands((7, hourAgo), against: 7), true, "stamp: nothing written since the copy was read, it stands")
        expect(Firestore.stands((7, hourAgo), against: 8), false, "stamp: one write since, it is read again")
        expect(Firestore.stands((7, hourAgo), against: nil), false, "stamp: a count not every writer keeps proves nothing")
        expect(Firestore.stands(nil, against: 7), false, "stamp: a copy from the mirror has no count to stand on")
        expect(Firestore.stands((7, Date().addingTimeInterval(-7 * 3600)), against: 7), false,
               "stamp: after six hours a writer that does not count gets its read")
        let stampDoc = try? JSONDecoder().decode(Firestore.Document.self, from: Data(
            #"{"name":"p/settings/stamp","fields":{"todos":{"integerValue":"12"},"phone":{"booleanValue":true},"fleet":{"booleanValue":true}}}"#.utf8))
        let read = Firestore.Stamp(stampDoc)
        expect(read.counts == ["todos": 12] && read.sure, true, "stamp: counts are the integers, and the phone's flag makes them sure")
        expect(Firestore.Stamp(nil).sure, false, "stamp: no document yet, nothing is sure")
        let mirrored = try? JSONDecoder().decode(Firestore.Page.self, from: Data(
            #"{"readAt":"2026-10-12T04:05:19.000Z","documents":[]}"#.utf8))
        expect(mirrored?.readAt == stamp.date(from: "2026-10-12T04:05:19Z"), true, "mirror: its page says when Firestore was read")
    }

    // MARK: - Grid

    /// Which directories the grid shows unfolded: every one that fits, the one holding the most
    /// sessions first, a smaller one where that one does not fit, none on a grid already full.
    private static func grid(_ expect: (Bool, Bool, String) -> Void) {
        let grid = FleetLayout(tile: CGSize(width: 310, height: 186), spacing: 26, columns: 2,
                               openSize: .zero, openHeight: 0, progress: 0)
        // A group of four, a session alone, a group of two — unfolded, 100pt a session, and
        // 150 on the larger cards.
        func laid(_ sizes: [Int] = [4, 1, 2], room: CGFloat) -> FleetLayout {
            grid.unfolding(sizes, room: room) { CGSize(width: 646, height: CGFloat($0) * ($1 ? 150 : 100)) }
        }
        func unfolded(_ sizes: [Int] = [4, 1, 2], room: CGFloat) -> [Bool] {
            laid(sizes, room: room).wide.map { $0 != nil }
        }
        expect(unfolded(room: 838) == [true, false, true], true, "grid: both directories unfolded when both fit")
        expect(unfolded(room: 837) == [true, false, false], true, "grid: the bigger one alone when both do not")
        expect(unfolded(room: 611) == [false, false, true], true, "grid: the smaller one when the bigger does not fit")
        expect(unfolded(room: 411) == [false, false, false], true, "grid: none when neither fits")
        expect(unfolded([2, 2], room: 425) == [true, false], true, "grid: of two the same size, the first")
        let rest = laid(room: 838).rest(3)
        expect(rest.frames.map(\.minY) == [0, 652, 426] && rest.height == 838, true,
               "grid: unfolded directories lead, the other sessions under them")
        expect(laid(room: 838).large == [] && laid(room: 938).large == [2] && laid(room: 1138).large == [0, 2], true,
               "grid: the larger cards where room is left once every directory that fits is unfolded")
        // The panel's own grid: three columns of 212 and two gaps of 26.
        func size(_ count: Int, large: Bool = false) -> CGSize {
            GroupTile.size(holding: count, large: large, in: 688, spacing: 26)
        }
        let cell = GroupTile.cell(688, spacing: 26)
        expect(cell == CGSize(width: 212, height: SessionTile.height)
               && size(6).height - size(3).height == cell.height + 26, true,
               "grid: an unfolded directory stands its sessions in the grid's own cells, three to a row")
        expect(size(1, large: true).height == size(2, large: true).height
               && size(3, large: true).height - size(2, large: true).height
                   == SessionTile.height(width: GroupTile.inner(688, large: true, spacing: 26)) + GroupTile.gap(26), true,
               "grid: and two to a row on the larger cards")
        expect(size(2) == CGSize(width: 450, height: SessionTile.height) && size(3).width == 688
               && size(2, large: true).width == 688, true,
               "grid: a directory of two takes two cells' room, in width and height")
        let inside = GroupTile.flushCards("s14", count: 2, in: 688, spacing: 26)
        expect(abs(2 * inside.card.width + inside.first + 2 * GroupTile.inset - 450) < 0.001
               && inside.card.height == SessionTile.height - 2 * GroupTile.inset
               && inside.first > GroupTile.inset, true,
               "grid: its cards inside its border, further apart where its name stands between them")
        expect(size(4).width == 450 && size(4).height - size(2).height == cell.height + 26
               && size(5).width == 688, true,
               "grid: four stand two and two, five three and two")
        expect(size(4, large: true).height + 26 + SessionTile.height <= 658, true,
               "grid: four on the larger cards stand over one row of the grid on a laptop screen")
        var beside = FleetLayout(tile: CGSize(width: 212, height: SessionTile.height), spacing: 26,
                                 columns: 3, openSize: .zero, openHeight: 0, progress: 0)
        beside.wide = [size(2), nil, nil]
        let besideRest = beside.rest(3)
        expect(besideRest.frames[1].minX == 476 && besideRest.frames[1].maxY == size(2).height
               && besideRest.frames[2].origin == CGPoint(x: 0, y: size(2).height + 26), true,
               "grid: a session stands beside a directory two columns wide, level with its foot, the next under them")
        let roomy = beside.unfolding([2, 1], room: 2000) { size($0, large: $1) }
        expect(roomy.large.isEmpty && roomy.wide[0] == size(2), true,
               "grid: a directory two wide keeps its smaller cards while a session can stand beside it")
        let two = GroupTile.alone(holding: 2, room: 700, in: 646, spacing: 26)
        let eight = GroupTile.alone(holding: 8, room: 300, in: 646, spacing: 26)
        expect(two.large && two.size == CGSize(width: 646, height: 700)
               && !eight.large && eight.size == CGSize(width: 646, height: 300), true,
               "grid: a directory given the block takes the whole of it, whatever its cards need")
    }

    // MARK: - Money

    /// What the SPENDING block makes of an export: a category that carries a comma stays one
    /// field, a credit is not spending, and the newest month comes first.
    private static func money(_ expect: (Bool, Bool, String) -> Void) {
        let csv = """
        date,amount,category,merchant
        2026-09-30,-10.00,"Restaurants, fast food & coffee",A
        2026-10-01,-4.50,Train,B
        2026-10-02,-250.00,Loan repayment,C
        2026-10-02,20.00,Salary,D
        2026-10-02,-1.00,Vet,E
        2026-10-03,-2.50,Shopping,F,x,100,104
        2026-10-04,-2.50,Shopping,F,x,100,104
        2026-10-04,-3.00,Shopping,F,x,100,106
        2026-10-05,-40.00,Own savings,G
        """
        let read = Money.months(csv: csv)
        expect(read.months.map(\.id) == ["2026-10", "2026-09"], true, "money: the newest month first")
        expect(read.months.first?.spent
               == [.transport: 4.5, .loan: 250.00, .health: 1, .clothes: 5, .shopping: 3], true,
               "money: a month cut by kind, a credit and a move to savings left out, clothes by the bank's code")
        expect(read.months.last?.spent == [.food: 10], true, "money: a quoted category keeps its comma")
        expect(read.latest == "2026-10-05", true, "money: the day of the newest line, spent or not")
        expect(read.months.first?.shares.values.reduce(0, +) == 100, true, "money: a month's shares add up to 100")
        expect(read.months.last?.shares[.food] == 100, true, "money: one kind alone is the whole month")
        expect(read.months.first?.ranked == [.loan, .clothes, .transport, .shopping], true,
               "money: a month's kinds the largest first, one that reads 0% left out")
        // One large slice and five small ones that end at twelve o'clock, where their names
        // would sit on top of one another.
        let crowded = Money.Month(id: "2026-10", spent: [.food: 62, .transport: 12, .leisure: 9,
                                                         .clothes: 8, .subscriptions: 6, .health: 3])
        let callouts = crowded.callouts(of: Set(crowded.ranked), radius: 48, reach: 10, line: 11.5, longest: 34)
        expect(callouts.filter(\.right).map(\.kind) == [.food] && callouts.count == 6, true,
               "money: a slice's name on its side of the pie")
        // The quarter up to twelve o'clock, where the small slices end: each name over the last.
        let heights = callouts.filter { $0.turn > 0.75 }.map { -$0.point(radius: 48, past: $0.length).y }
        expect(heights.count == 4 && zip(heights, heights.dropFirst()).allSatisfy { $1 - $0 >= 11.499 }
               && callouts.allSatisfy { $0.length >= 10 && $0.length <= 34 }, true,
               "money: names that would touch part, each further out along its own radius")
        // The same month in a larger pie: the largest slice holds its name, the others have
        // theirs past the rim, two lines each.
        let tall = crowded.callouts(of: Set(crowded.ranked).subtracting([.food]), radius: 100, reach: 16,
                                    line: 25, longest: 90)
        let stacked = tall.filter { $0.turn > 0.75 }.map { -$0.point(radius: 100, past: $0.length).y }
        expect(tall.map(\.kind) == [.transport, .leisure, .clothes, .subscriptions, .health]
               && zip(stacked, stacked.dropFirst()).allSatisfy { $1 - $0 >= 24.999 }
               && tall.allSatisfy { $0.length <= 90 }, true,
               "money: an arrow for the slices named and no other, two lines of room each")
        expect(crowded.kind(at: CGPoint(x: 10, y: 0), radius: 100) == .food
               && crowded.kind(at: CGPoint(x: -1, y: -40), radius: 100) == .health
               && crowded.kind(at: CGPoint(x: 0, y: 101), radius: 100) == nil, true,
               "money: the slice under the pointer, and none past the rim")
        // A name 45 wide, 9pt inside the rim of the largest pie: 10% holds it, 5% does not.
        expect(Money.arc(from: 0.4, to: 0.5, out: 115) >= 45 && Money.arc(from: 0.95, to: 1, out: 115) < 45, true,
               "money: a name is written along a rim long enough for it, less 3pt either side")
        // A name over its price, two lines 45 wide: the largest slice holds them out by the
        // rim, a sliver nowhere. At six o'clock, where a label lies across its slice, 12%
        // holds lines 40 wide and none 60 wide.
        let wide = Money.seat([45, 45], line: 11, from: 0, to: 0.62, radius: 100)
        let across = Money.seat([40, 40], line: 11, from: 0.44, to: 0.56, radius: 100)
        expect(wide.map { $0 > 60 } == true
               && Money.seat([45, 45], line: 11, from: 0.97, to: 1, radius: 100) == nil
               && Money.seat([60, 60], line: 11, from: 0.44, to: 0.56, radius: 100) == nil
               && across.map { $0 > 60 && $0 <= 97 } == true, true,
               "money: a name sits on straight lines in the slice wide enough for them, as far out as it fits")
        // Each line is held to its own width: 15% at eight o'clock has room for a long name
        // over a shorter price, not for two lines as long as the name.
        expect(Money.seat([60, 50], line: 9.5, from: 0.615, to: 0.765, radius: 100) != nil
               && Money.seat([60, 60], line: 9.5, from: 0.615, to: 0.765, radius: 100) == nil, true,
               "money: a short line under a long one sits where two long ones would not")
        // A large slice of a small pie: the label goes back towards the centre.
        expect(Money.seat([50, 50], line: 9.5, from: 0, to: 0.46, radius: 70).map { $0 < 42 } == true, true,
               "money: a label too long for the outer half of its slice sits nearer the centre")
        // The share under the pointer keeps nearer the centre than the name over it, and as
        // near the middle of its slice as it fits: there in a wide one, further out in a thin.
        expect(Money.seat([26], line: 12, from: 0, to: 0.62, radius: 100, within: 60)
                   .map { $0 > 40 && $0 < 50 } == true
               && Money.seat([26], line: 12, from: 0, to: 0.62, radius: 100, within: 60, near: 30) == 30
               && Money.seat([18], line: 10, from: 0.95, to: 1, radius: 124, near: 62)
                   .map { $0 > 62 && $0 < 84 } == true, true,
               "money: a line told where to be sits there, or as near it as its slice has room")

        let passing = Money.months(csv: """
        date,amount,category,merchant
        2026-08-10,-250.00,Loan repayment,A
        2026-08-12,-30.00,Train,C
        2026-08-28,260.00,"Parents, loan instalment cover",B
        2026-09-10,-250.00,Loan repayment,A
        2026-09-20,100.00,"Parents, loan instalment cover",B
        2026-10-10,-250.00,Loan repayment,A
        2026-10-11,-5.00,Train,C
        """).months
        expect(passing.map(\.spent) == [[.transport: 5], [.loan: 150], [.transport: 30]], true,
               "money: a debit a credit was sent to cover is not spent, past what the credit paid")
        expect(passing.map(\.covered) == [[:], [.loan: 100], [.loan: 250]], true,
               "money: what a cover paid, never more than the debit")
        expect(passing.map(\.awaited) == [[.loan: 250], [:], [:]], true,
               "money: in the newest month a debit whose cover is still to come waits apart")
    }

    // MARK: - Reels

    /// When a Reel that failed is tried again, and when it is given up on and named in ALERT.
    private static func reels(_ expect: (Bool, Bool, String) -> Void) {
        let now = Date()
        func reel(tries: Int?, triedAgo: TimeInterval?, status: String = "pending") -> Reel {
            var fields = ["status": ["stringValue": status]]
            if let tries { fields["fleetTries"] = ["integerValue": String(tries)] }
            if let triedAgo {
                fields["fleetTriedAt"] = ["timestampValue":
                    ISO8601DateFormatter().string(from: now.addingTimeInterval(-triedAgo))]
            }
            let json = try! JSONSerialization.data(withJSONObject: ["name": "factcheck/x", "fields": fields])
            return Reel(try! JSONDecoder().decode(Firestore.Document.self, from: json))
        }
        expect(reel(tries: nil, triedAgo: nil).needsCheck(at: now), true, "a Reel never tried is checked")
        expect(reel(tries: 1, triedAgo: 600).needsCheck(at: now), false,
               "a Reel that failed ten minutes ago waits")
        expect(reel(tries: 1, triedAgo: 3600).needsCheck(at: now), true,
               "a Reel that failed an hour ago is tried again")
        expect(reel(tries: nil, triedAgo: 3600).needsCheck(at: now), true,
               "a failure from before the count gets its retries")
        expect(reel(tries: Reel.maxTries, triedAgo: 86_400).needsCheck(at: now), false,
               "a Reel out of tries is left alone")
        expect(reel(tries: Reel.maxTries, triedAgo: 86_400).givenUp, true, "and is the one ALERT names")
        expect(reel(tries: 2, triedAgo: 600).givenUp, false, "a Reel with a try left is not in ALERT")
        expect(reel(tries: 1, triedAgo: 3600, status: "done").needsCheck(at: now), false,
               "a checked Reel is not checked again")
    }

    // MARK: - Crons

    /// When a routine's run is hung: past its next slot, within the floor and the ceiling —
    /// see `Launchd.allowance`. The age is `ps`'s etime, which has three shapes.
    private static func crons(_ expect: (TimeInterval?, TimeInterval?, String) -> Void) {
        expect(Launchd.parseElapsed("02-16:12:30"), 2 * 86400 + 16 * 3600 + 12 * 60 + 30, "etime with days")
        expect(Launchd.parseElapsed("16:12:30"), 16 * 3600 + 12 * 60 + 30, "etime with hours")
        expect(Launchd.parseElapsed("00:23"), 23, "etime under an hour")
        expect(Launchd.parseElapsed("1-2-03:04"), nil, "etime that is not one")
        let me = Int(getpid())
        expect(Launchd.elapsed([me])[me].map { $0 < 600 ? 1 : 0 }, 1, "ps answers for a live pid")

        let v3: [String: Any] = ["StartCalendarInterval": ["Minute": 5]]
        let epitech: [String: Any] = ["StartCalendarInterval": [8, 14, 20].map { ["Hour": $0, "Minute": 0] }]
        let weekdays: [String: Any] = ["StartCalendarInterval": (1...5).map { ["Weekday": $0, "Hour": 18, "Minute": 30] }]
        expect(Launchd.allowance(v3), 3600, "an hourly calendar job has an hour")
        expect(Launchd.allowance(epitech), 6 * 3600, "8h, 14h, 20h: the shortest gap, six hours")
        expect(Launchd.allowance(weekdays), 6 * 3600, "weekdays at 18:30: a day, down to the ceiling")
        expect(Launchd.allowance(["StartInterval": 60]), 300, "every minute: up to the floor")
        expect(Launchd.allowance(["StartInterval": 43200]), 6 * 3600, "every 12h: down to the ceiling")
        expect(Launchd.allowance(["WatchPaths": ["/tmp/x"]]), 6 * 3600, "a watched path: the ceiling")
        let online = ["/Users/mr/.local/bin/online", "/bin/bash", "routine.sh"]
        var v3online = v3
        v3online["ProgramArguments"] = online
        expect(Launchd.allowance(v3online), 3600 + 3 * 1295, "hourly under online: an hour and three waits of 21.5 min")
        expect(Launchd.hung(Launchd.parseElapsed("01:05:00"), v3online), nil,
               "a 20-min wait then a 45-min run is not hung")
        v3online["EnvironmentVariables"] = ["ONLINE_WAIT": "300"]
        expect(Launchd.allowance(v3online), 3600 + 3 * 395, "ONLINE_WAIT from the plist is the wait")
        var epitechOnline = epitech
        epitechOnline["ProgramArguments"] = online
        expect(Launchd.allowance(epitechOnline), 6 * 3600, "epitech under online: still the ceiling")
        v3online["ProgramArguments"] = ["/Users/mr/.local/bin/catchup"] + online
        expect(Launchd.allowance(v3online), 3600 + 3 * 395, "online behind catchup still waits")
        expect(Launchd.hung(Launchd.parseElapsed("02:10:00"), v3), 7800, "an hourly routine running 2h10 is hung")
        expect(Launchd.hung(Launchd.parseElapsed("40:00"), v3), nil, "one running 40 min is not")
        expect(Launchd.hung(Launchd.parseElapsed("04:00"), ["StartInterval": 60]), nil,
               "the mounts running 4 min are slow, not hung")
        expect(Launchd.hung(nil, v3), nil, "a routine between two runs is not hung")

        let now = Date()
        expect(Launchd.awake(3 * 3600, now: now, wake: now - 600), 600,
               "a run 3h old that slept through the night is 10 min awake")
        expect(Launchd.hung(Launchd.awake(3 * 3600, now: now, wake: now - 600), v3), nil,
               "and the routine is not hung for it")
        expect(Launchd.awake(1800, now: now, wake: now - 7200), 1800, "a run started after the wake keeps its etime")
        expect(Launchd.awake(1800, now: now, wake: nil), 1800, "no wake since boot: etime as is")
        expect(Launchd.wakeTime().map { $0 < now ? 1 : 0 } ?? 1, 1, "kern.waketime reads as a past date or nothing")
    }

    /// What a plist and one `launchctl list` line make of a card and of ALERT.
    private static func judging(_ expect: (Bool, Bool, String) -> Void) {
        let hourly: [String: Any] = ["StartCalendarInterval": ["Minute": 5]]
        let resident: [String: Any] = ["KeepAlive": true]
        let late = Launchd.judge("s14.x", hourly, (nil, 75), age: nil)
        expect(late.deferred && !late.failing && late.ok, true, "exit 75: deferred, not failing, still ok")
        let failed = Launchd.judge("s14.x", hourly, (nil, 1), age: nil)
        expect(failed.failing && !failed.ok && !failed.deferred, true, "exit 1: failing, not ok")
        expect(Launchd.judge("s14.x", hourly, (nil, -15), age: nil).failing, true, "a kill is a failure")
        expect(Launchd.judge("s14.x", hourly, nil, age: nil).ok, false, "a routine launchd does not list is not ok")
        let stuck = Launchd.judge("s14.x", hourly, (42, 0), age: 7800)
        expect(stuck.hung == 7800 && !stuck.ok && stuck.busy, true, "running 2h10 on an hourly slot: hung, not ok")
        let up = Launchd.judge("s14.web", resident, (42, 78), age: 3 * 86400)
        expect(up.ok && up.hung == nil, true, "a resident up for days with an old 78 is ok, never hung")
        expect(Launchd.judge("s14.web", resident, (nil, 0), age: nil).ok, false, "a resident with no pid is not ok")
        expect(Launchd.judge("s14.web", resident, (42, 75), age: nil).deferred, false,
               "a resident whose last exit was 75 is not deferred")

        var retrying = failed
        retrying.repairing = true
        let lines = AlertsBlock.cronAlerts([stuck, failed, retrying, late, up,
                                            Launchd.judge("s14.web", resident, (nil, 1), age: nil)])
        expect(lines == ["s14.x hung 2h", "s14.x"], true,
               "ALERT: the hung one with its age, the failed one by name, nothing else (got \(lines))")

        expect(Fixer.subject("s14.x hung 2h") == "s14.x", true,
               "a fix is filed under the routine, not under its age")
        expect(Fixer.prompt("s14.x hung 2h", crons: [stuck]).contains("LaunchAgents/s14.x.plist"), true,
               "a routine's fixer is pointed at its plist")
        expect(Fixer.prompt("edsquare", crons: [stuck]).contains("never discord.mjs"), true,
               "an Epitech reader's fixer is told to leave Discord alone")

        // The same Claude, without the click.
        expect(Fixer.subject("scan 16h old") == Fixer.subject("scan 15h old"), true,
               "a stale scan is the same alert an hour later")
        var auto = Fixer.Auto()
        expect(auto.due(["edsquare"], failing: [], now: 0).isEmpty, true,
               "an alert just up waits: most clear by themselves")
        expect(auto.due(["edsquare"], failing: [], now: Fixer.autoAfter) == ["edsquare"], true,
               "ten minutes on, a Claude goes out on it")
        expect(auto.due(["edsquare"], failing: [], now: 90_000).isEmpty, true,
               "and no second one for as long as it stands")
        _ = auto.due([], failing: [], now: 90_010)
        _ = auto.due(["edsquare"], failing: [], now: 90_020)
        expect(auto.due(["edsquare"], failing: [], now: 90_020 + Fixer.autoAfter).isEmpty, true,
               "off the bar for the seconds of a restart, it has not gone")
        _ = auto.due([], failing: [], now: 91_000)
        _ = auto.due([], failing: [], now: 91_000 + Fixer.autoAfter)
        _ = auto.due(["edsquare"], failing: [], now: 91_610)
        expect(auto.due(["edsquare"], failing: [], now: 91_610 + Fixer.autoAfter).count == 1, true,
               "ten minutes off it and back is a new failure: another")
        _ = auto.due([], failing: [], now: 93_000)
        _ = auto.due([], failing: [], now: 93_000 + Fixer.autoAfter)
        _ = auto.due(["edsquare"], failing: [], now: 93_610)
        expect(auto.due(["edsquare"], failing: [], now: 93_610 + Fixer.autoAfter).isEmpty, true,
               "but not within three hours of the last")
        expect(auto.due(["edsquare"], failing: [], now: 92_210 + Fixer.autoGap).count == 1, true,
               "three hours after it, yes")
        var routine = Fixer.Auto()
        _ = routine.due(["s14.x"], failing: ["s14.x"], now: 0)
        _ = routine.due(["s14.x"], failing: ["s14.x"], now: Fixer.autoAfter)
        _ = routine.due([], failing: ["s14.x"], now: 20_000)
        _ = routine.due(["s14.x"], failing: ["s14.x"], now: 20_010)
        expect(routine.due(["s14.x"], failing: ["s14.x"], now: 40_000).isEmpty, true,
               "a routine off the bar while Fleet retries it has not gone")

        // What that Claude is sent on is the scan's file as it is now, not as the last fetch
        // read it.
        let root = NSTemporaryDirectory() + "fleet-selftest-scan-\(getpid())"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let state = URL(fileURLWithPath: root + "/state.json")
        let stamp = ISO8601DateFormatter().string(from: Date())
        func verdicts(discord: Int, at: Date) {
            let sources = root + "/sources.json"
            try? #"{"at":"\#(stamp)","scan":0,"edsquare":0,"outlook":0,"discord":\#(discord),"calendar":0}"#
                .write(toFile: sources, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: sources)
        }
        try? #"{"generatedAt":"\#(stamp)","sessionOk":true,"errors":[],"registrations":[],"deadlines":[]}"#
            .write(to: state, atomically: true, encoding: .utf8)
        let hub = HubStore()
        verdicts(discord: 1, at: Date())
        hub.rereadEpitechIfWritten(state)
        expect(hub.epitech?.failure == "discord", true, "a reader that failed is on the bar")
        verdicts(discord: 0, at: Date().addingTimeInterval(60))
        hub.rereadEpitechIfWritten(state)
        expect(hub.epitech?.failure == nil, true,
               "and off it once a later run has written a 0, with no fetch in between")
    }

    /// The retry state machine, on labels launchd does not have, with the kickstart counted
    /// rather than sent: what is checked is what Fleet remembers and what ALERT waits for.
    private static func repairs(_ expect: (Bool, Bool, String) -> Void) {
        let key = "cronRetries", deferredKey = "cronDeferred"
        let saved = UserDefaults.standard.object(forKey: key)
        let savedDeferred = UserDefaults.standard.object(forKey: deferredKey)
        defer {
            UserDefaults.standard.set(saved, forKey: key)
            UserDefaults.standard.set(savedDeferred, forKey: deferredKey)
        }
        let store = LaunchdStore()
        store.repairs = true
        var kicked: [String] = []
        store.kick = { kicked.append($0); return true }
        func job(_ id: String, enabled: Bool = true, failing: Bool = false, busy: Bool = false,
                 deferred: Bool = false, hung: TimeInterval? = nil, allowance: TimeInterval = 3600) -> Launchd.Job {
            Launchd.Job(id: id, name: id, schedule: "", enabled: enabled, failing: failing,
                        triggered: true, ok: !failing, note: "", busy: busy, deferred: deferred, hung: hung,
                        allowance: allowance)
        }
        func remembers(_ id: String, _ key: String = key) -> Bool {
            UserDefaults.standard.dictionary(forKey: key)?[id] != nil
        }
        let now = Date()
        var out = store.repair([job("selftest.a", failing: true), job("selftest.b", deferred: true)], now: now)
        expect(out[0].repairing && remembers("selftest.a") && kicked == ["selftest.a"], true,
               "a failed routine is started again, and ALERT waits")
        expect(remembers("selftest.b"), false, "a deferred one is not started again")
        _ = store.repair([job("selftest.a", enabled: false)], now: now)
        expect(remembers("selftest.a"), true, "launchd listing nothing does not forget the retry")
        out = store.repair([job("selftest.a", failing: true)], now: now + 120)
        expect(out[0].repairing, false, "the retry failed too: not started a third time, ALERT names it")
        out = store.repair([job("selftest.a", failing: true, busy: true, hung: 7200)], now: now + 120)
        expect(out[0].repairing, false, "a retry that hangs is not waited for")
        _ = store.repair([job("selftest.e", busy: true, hung: 7200)], now: now)
        expect(remembers("selftest.e"), true, "a hung run spends the retry")
        _ = store.repair([job("selftest.e", busy: true, hung: 7210)], now: now + 10)
        expect(remembers("selftest.e"), true, "and keeps it spent while it hangs on an exit 0")
        out = store.repair([job("selftest.e", failing: true)], now: now + 20)
        expect(!out[0].repairing && !kicked.contains("selftest.e"), true,
               "killed by hand, it is named in ALERT, not started again")
        _ = store.repair([job("selftest.a")], now: now + 180)
        expect(remembers("selftest.a"), false, "a clean run forgets the retry")
        _ = store.repair([job("selftest.c", failing: true)], now: now)
        _ = store.repair([job("selftest.d")], now: now)
        expect(remembers("selftest.c"), false, "a routine gone from the folder is forgotten")
        _ = store.repair([job("selftest.h", failing: true)], now: now)
        _ = store.repair([], now: now, files: ["selftest.h"])
        expect(remembers("selftest.h"), true, "a plist that does not parse keeps its retry")
        var writes = 0
        let watch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                           object: nil, queue: nil) { _ in writes += 1 }
        _ = store.repair([job("selftest.h", failing: true)], now: now + 1)
        expect(writes == 0, true, "nothing changed, nothing written (\(writes) writes)")
        _ = store.repair([job("selftest.h")], now: now + 2)
        NotificationCenter.default.removeObserver(watch)
        expect(writes > 0, true, "a change is written (\(writes) writes)")

        out = store.repair([job("selftest.f", deferred: true)], now: now)
        expect(out[0].deferredFor == nil && remembers("selftest.f", deferredKey), true,
               "a first deferred run is remembered, not in ALERT")
        out = store.repair([job("selftest.f", deferred: true)], now: now + 5 * 3600)
        expect(out[0].deferredFor == nil, true, "deferred for 5h on an hourly slot: still a wifi outage")
        out = store.repair([job("selftest.f", deferred: true)], now: now + 7 * 3600)
        expect(AlertsBlock.cronAlerts(out) == ["selftest.f deferred 7h"], true,
               "deferred for 7h: ALERT says so (got \(AlertsBlock.cronAlerts(out)))")
        out = store.repair([job("selftest.f", deferred: true, allowance: 3 * 3600)], now: now + 7 * 3600)
        expect(out[0].deferredFor == nil, true, "a 3h allowance waits for 9h")
        _ = store.repair([job("selftest.f", enabled: false)], now: now + 7 * 3600)
        expect(remembers("selftest.f", deferredKey), true, "launchd listing nothing does not reset it")
        _ = store.repair([job("selftest.f", failing: true)], now: now + 8 * 3600)
        expect(remembers("selftest.f", deferredKey), false, "any other exit does")
        _ = store.repair([job("selftest.g", deferred: true)], now: now)
        _ = store.repair([job("selftest.d")], now: now)
        expect(remembers("selftest.g", deferredKey), false, "a deferred routine gone from the folder is forgotten")
        _ = store.repair([job("my-setup.sync", failing: true)], now: now)
        expect(kicked.contains("my-setup.sync"), false, "my-setup.sync is not started again")
        var returns = 0
        store.onNetworkBack = { returns += 1 }
        store.network(true)
        _ = store.repair([job("selftest.w", deferred: true)], now: now)
        expect(kicked.contains("selftest.w"), false, "a network up all along starts no deferred run at once")
        store.network(false)
        store.network(true)
        expect(returns == 1, true, "the network back is told once to what waits on it outside the store")
        _ = store.repair([job("selftest.w", deferred: true), job("selftest.x", busy: true, deferred: true)], now: now)
        expect(kicked.filter { $0 == "selftest.w" }.count == 1 && !kicked.contains("selftest.x"), true,
               "the network back starts a deferred run once, not one already going")
        _ = store.repair([job("selftest.w", deferred: true)], now: now)
        expect(kicked.filter { $0 == "selftest.w" }.count == 1, true, "and only on that return")
        _ = store.repair([job("selftest.w", deferred: true)], now: now + LaunchdStore.deferredRetry)
        expect(kicked.filter { $0 == "selftest.w" }.count == 2, true,
               "still deferred an hour on with the network up: started again")
        store.network(false)
        _ = store.repair([job("selftest.w", deferred: true)], now: now + 3 * LaunchdStore.deferredRetry)
        expect(kicked.filter { $0 == "selftest.w" }.count == 2, true, "not while the network is down")
    }

    // MARK: - Listening ports

    /// Where a KeepAlive job answers is read out of `lsof`, and the one rule that is not
    /// obvious is which port wins when a process holds several: the lowest, not the first
    /// printed. `lsof` prints in file-descriptor order, so tailscaled's SOCKS proxy came
    /// after whatever it had dialled out on.
    private static func ports(_ expect: (Int, Int, String) -> Void) {
        let captured = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        Python    52741   mr    3u  IPv4 0x1a2b3c4d5e6f7080      0t0  TCP 127.0.0.1:8766 (LISTEN)
        Python    52802   mr    3u  IPv4 0x1a2b3c4d5e6f7081      0t0  TCP 127.0.0.1:8767 (LISTEN)
        Python    52860   mr    4u  IPv4 0x1a2b3c4d5e6f7082      0t0  TCP 127.0.0.1:8768 (LISTEN)
        tailscal  51900   mr   11u  IPv6 0x1a2b3c4d5e6f7083      0t0  TCP [::1]:41641 (LISTEN)
        tailscal  51900   mr   12u  IPv4 0x1a2b3c4d5e6f7084      0t0  TCP 127.0.0.1:1055 (LISTEN)
        """
        let found = Launchd.parseListening(captured)
        expect(found[52741] ?? 0, 8766, "the first server's port comes off its pid")
        expect(found[52802] ?? 0, 8767, "the second server's port comes off its pid")
        expect(found[52860] ?? 0, 8768, "the third server's port comes off its pid")
        expect(found[51900] ?? 0, 1055, "a process on two ports shows the lower one")
        expect(found[1] ?? 0, 0, "a pid that listens on nothing has no port")
    }

    // MARK: - Hooks against the transcript

    /// A prompt typed during a turn is queued: its hook fires as it is typed, the turn's Stop
    /// then says ready, and the queued prompt starts 42 ms later with no hook of its own.
    /// A first prompt held behind the SessionStart hooks: the screen of 01-10, when one of them
    /// hung for its 60 s timeout and the tile said READY throughout.
    private static func heldPrompt(_ expect: (Bool, Bool, String) -> Void) {
        let box = """
        ────────────────
        ❯
        ────────────────
          fleet | Opus 5.5 – xhigh | 0% token – 1M | @main – up to date
          ▸▸ bypass permissions on (shift+tab to cycle)
        """
        let held = "❯ fleet should have a way\n\n+ Marinating… (running SessionStart hooks… 6/7 · 10s)\n\n" + box
        expect(TerminalWatch.read(held) == .working, true, "a prompt held behind SessionStart hooks is work")
        expect(TerminalWatch.read(box) == .unknown, true, "the same screen with no spinner says nothing")
        // The screen of 07-10: eight minutes into one thought, the tile said NEEDS YOU.
        let thinking = "❯ then the next one\n\n· Roosting… (8m 37s · ↓ 15.0k tokens · deep in thought with xhigh effort)\n\n" + box
        expect(TerminalWatch.read(thinking) == .working, true, "a long thought, words after the token counter, is work")
        let writing = "❯ call it spending\n\n· Precipitating… (3m 7s · ↓ 12.0k tokens)\n\n" + box
        expect(TerminalWatch.read(writing) == .working, true, "the plain spinner is still work")
        // The screen of 12-10: a first thought, no token counter until its block lands.
        let silent = "❯ make the circle bigger\n\n✱ Billowing… (4m 39s · deep in thought with xhigh effort)\n\n" + box
        expect(TerminalWatch.read(silent) == .working, true, "a spinner with no token counter yet is work")
        let quoted = "❯ why blue on Billowing… (4m 39s · deep in thought with xhigh effort)\n\n" + box
        expect(TerminalWatch.read(quoted) == .unknown, true, "a spinner quoted in a prompt is not one")
    }

    private static func queuedPrompt(_ expect: (Int, Int, String) -> Void) {
        let path = NSTemporaryDirectory() + "fleet-selftest-queued-\(getpid()).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stop = Date().addingTimeInterval(-10)
        func stamp(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: d)
        }
        try? (#"{"type":"user","timestamp":"\#(stamp(stop.addingTimeInterval(0.042)))","cwd":"/tmp","message":{"content":[{"type":"text","text":"why does the bar move"}]}}"# + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        let info = TranscriptStore().info(for: path)
        let ready = Hooks.Record(state: .ready, at: Date(timeIntervalSince1970: floor(stop.timeIntervalSince1970)), pids: [])
        expect(SessionRegistry.ranked(ready, heuristic: .running, info: info, cpu: 0, now: Date()) == .running ? 1 : 0, 1,
               "a queued prompt starting just after the Stop is work, not ready")
        let before = Hooks.Record(state: .ready, at: Date(timeIntervalSince1970: floor(stop.timeIntervalSince1970) + 1), pids: [])
        expect(SessionRegistry.ranked(before, heuristic: .running, info: info, cpu: 0, now: Date()) == .ready ? 1 : 0, 1,
               "and a Stop after the prompt still reads ready")
    }

    private static func freshSession(_ expect: (Int, Int, String) -> Void) {
        let path = NSTemporaryDirectory() + "fleet-selftest-fresh-\(getpid()).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let local = #"{"type":"user","timestamp":"2026-10-13T09:00:00.000Z","cwd":"/tmp","message":{"content":[{"type":"text","text":"<command-name>/model</command-name>"}]}}"# + "\n"
        try? local.write(toFile: path, atomically: true, encoding: .utf8)
        expect(TranscriptStore().info(for: path)?.untouched == true ? 1 : 0, 1,
               "a session that has only run a local command is still new")
        let reply = #"{"type":"assistant","timestamp":"2026-10-13T09:00:05.000Z","cwd":"/tmp","message":{"id":"m1","content":[{"type":"text","text":"Done."}]}}"# + "\n"
        try? (local + reply).write(toFile: path, atomically: true, encoding: .utf8)
        expect(TranscriptStore().info(for: path)?.untouched == false ? 1 : 0, 1,
               "and one Claude has answered is not")
    }

    // MARK: - Sub-agents

    /// A cold read starts `transcriptTailBytes` from the end, inside a line, and that line was in
    /// neither the head nor the tail. When it was the notification ending an agent, the tile
    /// counted the agent until the next restart (30-09: epitech, SUB-AGENTS 1 while READY).
    private static func cutLine(_ expect: (Int, Int, String) -> Void) {
        let root = NSTemporaryDirectory() + "fleet-selftest-cut-\(getpid())"
        let session = root + "/session.jsonl"
        let agents = root + "/session/subagents"
        try? FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try? #"{"agentType":"general-purpose","description":"Fares","toolUseId":"toolu_cut"}"#
            .write(toFile: agents + "/agent-c.meta.json", atomically: true, encoding: .utf8)
        try? "".write(toFile: agents + "/agent-c.jsonl", atomically: true, encoding: .utf8)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let ended = #"{"type":"user","timestamp":"\#(stamp)","message":{"content":"<task-notification>\n<tool-use-id>toolu_cut</tool-use-id>\n<status>completed</status>\n</task-notification>"}}"# + "\n"
        var text = #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_cut","name":"Agent","input":{"description":"Fares"}}]}}"# + "\n"
            + #"{"type":"user","timestamp":"\#(stamp)","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_cut","content":[{"type":"text","text":"Async agent launched successfully."}]}]}}"# + "\n"
            + ended
        // After it, exactly the tail's size less half of it: the cold read starts mid-notification.
        func filler(_ n: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"p","content":[{"type":"text","text":""#
                + String(repeating: "x", count: n) + #""}]}}"# + "\n"
        }
        let overhead = filler(0).utf8.count
        var rest = Config.transcriptTailBytes - ended.utf8.count / 2
        while rest > 4000 + 2 * overhead {
            text += filler(4000)
            rest -= filler(4000).utf8.count
        }
        text += filler(rest - overhead)
        try? text.write(toFile: session, atomically: true, encoding: .utf8)
        expect(TranscriptStore().info(for: session)?.unfinishedAgentIDs.count ?? -1, 0,
               "a notification cut by a cold read's start still ends its agent")
    }

    /// A transcript with an agent launched into the background, written the way Claude Code
    /// writes one: the call is answered at once, the agent's own file lives in a sibling
    /// directory, and the only thing that ever says it finished is a `<task-notification>`
    /// arriving turns later.
    private static func subagents(_ expect: (Int, Int, String) -> Void) {
        let root = NSTemporaryDirectory() + "fleet-selftest-\(getpid())"
        let session = root + "/session.jsonl"
        let agents = root + "/session/subagents"
        try? FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let call = "toolu_selftest"
        func stamp(_ secondsAgo: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
        }
        func append(_ line: String) {
            let data = Data((line + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: session) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: session))
            }
            // The store skips a file whose size and mtime have not moved, and a test that
            // writes twice in the same millisecond would read its own stale cache.
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: session)
        }

        try? #"{"agentType":"general-purpose","description":"Audit the palette","toolUseId":"\#(call)"}"#
            .write(toFile: agents + "/agent-x.meta.json", atomically: true, encoding: .utf8)
        try? #"""
        {"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(30))","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_inner","name":"Grep","input":{"pattern":"contrast"}}]}}
        """#.write(toFile: agents + "/agent-x.jsonl", atomically: true, encoding: .utf8)

        append(#"{"type":"user","timestamp":"\#(stamp(120))","cwd":"/tmp","message":{"content":[{"type":"text","text":"audit the palette"}]}}"#)
        append(#"{"type":"assistant","timestamp":"\#(stamp(119))","message":{"id":"m2","content":[{"type":"tool_use","id":"\#(call)","name":"Agent","input":{"description":"Audit the palette"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(118))","message":{"content":[{"type":"tool_result","tool_use_id":"\#(call)","content":[{"type":"text","text":"Async agent launched successfully."}]}]}}"#)
        append(#"{"type":"assistant","timestamp":"\#(stamp(117))","message":{"id":"m3","content":[{"type":"text","text":"Started it."}]}}"#)

        let store = TranscriptStore()
        let launched = store.info(for: session)
        expect(launched?.unfinishedAgentIDs.count ?? -1, 1,
               "an answered Agent call is still an agent out")
        expect(launched?.subagents.count ?? -1, 1,
               "and its own transcript is found and read")
        expect(launched?.hasPendingTool == true ? 1 : 0, 0,
               "with nothing pending on the main thread")

        append(#"{"type":"user","timestamp":"\#(stamp(5))","message":{"content":[{"type":"text","text":"<task-notification>\n<tool-use-id>\#(call)</tool-use-id>\n<status>completed</status>\n</task-notification>"}]}}"#)

        let done = store.info(for: session)
        expect(done?.unfinishedAgentIDs.count ?? -1, 0,
               "a task-notification ends it")
        expect(done?.subagents.count ?? -1, 0,
               "and the tile stops counting it")

        // Woken up again by a SendMessage: its meta still names the ended spawn.
        append(#"{"type":"assistant","timestamp":"\#(stamp(5))","message":{"id":"m3b","content":[{"type":"tool_use","id":"toolu_resume","name":"SendMessage","input":{"to":"x","message":"round 2"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(5))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_resume","content":[{"type":"text","text":"{\"success\":true,\"message\":\"Resuming agent x\",\"resumedAgentId\":\"x\"}"}]}]}}"#)
        expect(store.info(for: session)?.subagents.count ?? -1, 1,
               "an agent resumed by SendMessage is out again")
        append(#"{"type":"user","timestamp":"\#(stamp(5))","message":{"content":[{"type":"text","text":"<task-notification>\n<tool-use-id>toolu_resume</tool-use-id>\n<status>completed</status>\n</task-notification>"}]}}"#)
        expect(store.info(for: session)?.subagents.count ?? -1, 0,
               "until the notification naming the SendMessage")

        // Spawned further back than a cold read's tail, and nothing has ended it since.
        try? #"{"agentType":"general-purpose","description":"Fix the corners","toolUseId":"toolu_old"}"#
            .write(toFile: agents + "/agent-y.meta.json", atomically: true, encoding: .utf8)
        try? FileManager.default.copyItem(atPath: agents + "/agent-x.jsonl", toPath: agents + "/agent-y.jsonl")
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m3c","content":[{"type":"tool_use","id":"toolu_old","name":"Agent","input":{"description":"Fix the corners"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(4))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_old","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: y (internal ID)"}]}]}}"#)
        let padding = #"{"type":"assistant","timestamp":"\#(stamp(3))","message":{"id":"m3d","content":[{"type":"text","text":"\#(String(repeating: "x", count: 4000))"}]}}"#
        for _ in 0 ..< (Config.transcriptTailBytes / 4000 + 2) { append(padding) }
        expect(TranscriptStore().info(for: session)?.subagents.count ?? -1, 1,
               "an agent spawned before the parsed tail is still out after a restart")

        // Taken down with its session: the resume names it by its own id, and no call.
        append(#"{"type":"user","timestamp":"\#(stamp(2))","queueTranscriptOnly":true,"message":{"content":"<task-notification>\n<task-id>y</task-id>\n<status>stopped</status>\n<summary>1 background agent didn't finish before the previous session ended</summary>\n</task-notification>"}}"#)
        expect(TranscriptStore().info(for: session)?.subagents.count ?? -1, 0,
               "an agent its session took down with it is out no longer")

        // A shell moved to the background and then stopped by hand: no notification follows.
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m4","content":[{"type":"tool_use","id":"toolu_sh","name":"Bash","input":{"command":"sleep 99"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh","content":"Command did not complete within its 120s timeout and was moved to the background (ID: b1x2y3z). Output is being written to: /tmp/x"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a shell moved to the background is a shell out")
        append(#"{"type":"assistant","timestamp":"\#(stamp(2))","message":{"id":"m5","content":[{"type":"tool_use","id":"toolu_stop","name":"TaskStop","input":{"task_id":"b1x2y3z"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(1))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_stop","content":"{\"message\":\"Successfully stopped task: b1x2y3z (sleep 99)\",\"task_id\":\"b1x2y3z\"}"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "and TaskStop ends it")

        // Finished while a turn was running: the notification is queued, and written as an
        // attachment rather than a user entry. A prompt typed over a working session, likewise.
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m6","content":[{"type":"tool_use","id":"toolu_sh2","name":"Bash","input":{"command":"sleep 99"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh2","content":"Command running in background with ID: b2x2y2z. Output is being written to: /tmp/y"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a shell started in the background is a shell out")
        append(#"{"type":"attachment","timestamp":"\#(stamp(2))","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>b2x2y2z</task-id>\n<tool-use-id>toolu_sh2</tool-use-id>\n<status>completed</status>\n</task-notification>"}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "and a queued task-notification ends it")
        // Done before its own tool_result is written: the notification is stamped first.
        append(#"{"type":"attachment","timestamp":"\#(stamp(4))","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>b4x4y4z</task-id>\n<tool-use-id>toolu_sh4</tool-use-id>\n<status>completed</status>\n</task-notification>"}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh4","content":"Command running in background with ID: b4x4y4z. Output is being written to: /tmp/w"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "a notification stamped before its shell's launch still ends it")
        // A workflow reports back the same way a background shell does, and its journal says
        // how far it has got: the phase of the last agent started, that phase's agents done.
        // The last line is half-written, as it is while an agent is being started.
        let wf = root + "/session/subagents/workflows/wf_1"
        try? FileManager.default.createDirectory(atPath: wf, withIntermediateDirectories: true)
        try? #"export const meta = { name: 'break-history-audit', phases: [{ title: 'Map' }, { title: 'Verify', detail: 'x' }, { title: 'Synthesize' }] }"#
            .write(toFile: root + "/wf.js", atomically: true, encoding: .utf8)
        try? [#"{"type":"launched"}"#,
              #"{"type":"started","key":"k1","agentId":"a1","label":"map","phase":"Map"}"#,
              #"{"type":"result","key":"k1","value":"long"}"#,
              #"{"type":"started","key":"k2","agentId":"a2","label":"v:1","phase":"Verify"}"#,
              #"{"type":"started","key":"k3","agentId":"a3","label":"v:2","phase":"Verify"}"#,
              #"{"type":"result","key":"k2","value":"long"}"#,
              #"{"type":"started","key":"k4""#].joined(separator: "\n")
            .write(toFile: wf + "/journal.jsonl", atomically: true, encoding: .utf8)
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m7","content":[{"type":"tool_use","id":"toolu_wf","name":"Workflow","input":{"script":"x"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_wf","content":"Workflow launched in background. Task ID: w087be80a\nSummary: audit\nTranscript dir: \#(wf)\nScript file: \#(root)/wf.js\n"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a workflow launched is a task out")
        let pill = store.info(for: session)?.workflow?.pill() ?? "none"
        expect(pill == "50% · 0m left" ? 1 : 0, 1,
               "its journal reads as how far along and time to go (got \(pill))")
        append(#"{"type":"user","timestamp":"\#(stamp(2))","message":{"content":"<task-notification>\n<task-id>w087be80a</task-id>\n<tool-use-id>toolu_wf</tool-use-id>\n<status>completed</status>\n</task-notification>"}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "and its task-notification ends it")
        let before = store.info(for: session)?.lastPromptAt
        append(#"{"type":"attachment","timestamp":"\#(stamp(1))","attachment":{"type":"queued_command","commandMode":"prompt","prompt":[{"type":"text","text":"and the icons"}]}}"#)
        let after = store.info(for: session)
        expect(after?.lastPromptAt != nil && after?.lastPromptAt != before ? 1 : 0, 1,
               "a prompt queued over a running turn counts as a prompt")
        expect(after?.preview.last?.text == "and the icons" ? 1 : 0, 1,
               "and shows on the tile")

        // What a resume writes for a shell its last process took down: for the record, no turn.
        append(#"{"type":"assistant","timestamp":"\#(stamp(1))","message":{"id":"m8","content":[{"type":"text","text":"Done."}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(0))","queueTranscriptOnly":true,"origin":{"kind":"task-notification"},"message":{"content":"<task-notification>\n<task-id>b9x9y9z</task-id>\n<tool-use-id>toolu_gone</tool-use-id>\n<status>stopped</status>\n<summary>Background shell command didn't finish before the previous session ended</summary>\n</task-notification>"}}"#)
        let resumed = store.info(for: session)
        expect(resumed?.turnOpen == false ? 1 : 0, 1,
               "a transcript-only notification after a resume opens no turn")
        expect(resumed?.preview.last?.text == "Done." ? 1 : 0, 1,
               "and is not a line on the tile")

        // What a compaction writes when it runs on a session idle at its prompt.
        append(#"{"type":"user","timestamp":"\#(stamp(0))","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued from a previous conversation that ran out of context."}}"#)
        let compacted = store.info(for: session)
        expect(compacted?.turnOpen == false ? 1 : 0, 1,
               "the summary of an idle compaction opens no turn")
        expect(compacted?.preview.last?.text == "Done." ? 1 : 0, 1,
               "and is not a line on the tile")

        // A shell started well before the tail a cold read covers, and nothing ending it since:
        // a Fleet started now must still count it.
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m8","content":[{"type":"tool_use","id":"toolu_sh3","name":"Bash","input":{"command":"sleep 99"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh3","content":"Command running in background with ID: b3x3y3z. Output is being written to: /tmp/z"}]}}"#)
        let filler = #"{"type":"assistant","timestamp":"\#(stamp(2))","message":{"id":"m9","content":[{"type":"text","text":"\#(String(repeating: "x", count: 4000))"}]}}"#
        for _ in 0 ..< (Config.transcriptTailBytes / 4000 + 2) { append(filler) }
        expect(TranscriptStore().info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a shell started before the parsed tail is still a shell out after a restart")
    }

    // MARK: - Ghosts

    /// Two real processes, told apart only by the `CLAUDE_PID` they were started with: one names
    /// a pid nothing holds, the other names this process, which is alive and started first.
    private static func ghosts(_ expect: (Bool, Bool, String) -> Void) {
        var dead: pid_t = 99_000
        while kill(dead, 0) == 0 { dead += 1 }
        let installed = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-check/Applications/sleep")
        try? FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installed)
        try? FileManager.default.copyItem(atPath: "/bin/sleep", toPath: installed.path)
        func spawn(owner: pid_t, from binary: String = "/bin/sleep") -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = ["30"]
            p.environment = ["CLAUDE_PID": String(owner)]
            try? p.run()
            return p
        }
        let orphan = spawn(owner: dead), child = spawn(owner: getpid())
        let app = spawn(owner: dead, from: installed.path)
        defer { orphan.terminate(); child.terminate(); app.terminate() }
        usleep(200_000)

        let found = Dictionary(uniqueKeysWithValues: Reaper.candidates().map { ($0.pid, $0.kind) })
        expect(found[orphan.processIdentifier] == .ghost, true, "ghosts: a tool process is a candidate")
        expect(app.isRunning && found[app.processIdentifier] == nil, true,
               "an installed app a session opened is not a ghost")
        expect(Reaper.ownerGone(orphan.processIdentifier), true, "its session gone, it is a ghost")
        expect(Reaper.ownerGone(child.processIdentifier), false, "its session alive, it is left alone")
    }
}
