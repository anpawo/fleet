import Foundation

/// Which project wears which tile number, pinned by hand.
///
/// Numbers are otherwise handed out in the order sessions start, which makes ⌘2 a different
/// project every morning. A pinned number belongs to its project and to nothing else: it is
/// held empty while that project is not running rather than lent to whoever started next,
/// because a number you have to check before pressing is not a shortcut.
///
/// A text file rather than a row of pickers in the settings window: nine projects is nine
/// lines, it is read far more often than it is changed, and any editor beats a dropdown.
@MainActor
enum Slots {

    /// Alongside the hook state, which is the other thing in here you may want to look at.
    /// `.txt` rather than `.conf` so double-clicking it opens something.
    static let path = (Hooks.home as NSString).appendingPathComponent("slots.txt")

    private static var cache: [String: Int] = [:]
    private static var readAt: Date?
    private static var seeded = false

    /// Project name — what the tile says — to the number it wears.
    ///
    /// Re-read only when the file's timestamp moves, so a hand edit lands on the next refresh
    /// a few seconds later without a parse on every poll.
    static var pins: [String: Int] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date
        guard let stamp else {
            if !seeded { seeded = true; seed() }
            return [:]
        }
        if stamp != readAt {
            readAt = stamp
            cache = parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        }
        return cache
    }

    /// `<number> <project>`, one per line, `#` starts a comment.
    ///
    /// A line that doesn't parse is skipped in silence rather than reported: this file is
    /// typed by hand, and one typo must not cost you the eight numbers that were fine.
    static func parse(_ text: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let number = Int(fields[0]), (1 ... 9).contains(number)
            else { continue }
            out[String(fields[1])] = number
        }
        return out
    }

    /// Written on first launch with every ~/self project already listed and commented out, so
    /// the file explains itself and pinning one is a matter of deleting a `#`.
    private static func seed() {
        let root = NSHomeDirectory() + "/self"
        let projects = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { name in
                var isDirectory: ObjCBool = false
                return !name.hasPrefix(".")
                    && FileManager.default.fileExists(atPath: root + "/" + name,
                                                      isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted()

        var text = """
        # Fleet — which project wears which tile number.
        #
        # One "<number> <project>" per line, 1 to 9, like:
        #
        #     2 fleet
        #
        # The project is the name on the tile: the folder under ~/self, whatever
        # sub-directory the session is working in.
        #
        # A number listed here is that project's and nobody else's — no other session borrows
        # it while the project is away — so ⌘3 opens the same thing every time. Sessions with
        # no line here take the numbers nothing has claimed, oldest first, as before.
        #
        # Saved edits apply within a few seconds; no restart. Every project found under ~/self
        # is listed below — uncomment one and give it a number.

        """
        for project in projects { text += "\n# \(project)" }

        try? FileManager.default.createDirectory(atPath: Hooks.home,
                                                 withIntermediateDirectories: true)
        try? (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

extension Slots {

    /// `fleet --test-slots`. Numbering is the one thing here worth a check: it has to hold a
    /// pinned number empty, hand out the rest in start order, and leave a running tile where it
    /// was — three rules that only ever meet at runtime.
    static func selfCheck() -> Int {
        var failures = 0
        func expect(_ got: [String: Int], _ want: [String: Int], _ what: String) {
            if got == want { print("  ok    \(what)") } else {
                print("  FAIL  \(what)\n        want \(want.sorted { $0.key < $1.key })"
                      + "\n        got  \(got.sorted { $0.key < $1.key })")
                failures += 1
            }
        }

        let registry = SessionRegistry()
        func numbers(_ names: [String], pins: [String: Int]) -> [String: Int] {
            var sessions = DemoFleet.sessions(names.count)
            for (i, name) in names.enumerated() {
                let dir = NSHomeDirectory() + "/self/" + name
                sessions[i].proc.cwd = dir
                sessions[i].transcript?.cwd = dir
                sessions[i].proc.startedAt = Date(timeIntervalSince1970: Double(1000 + i))
            }
            registry.assignNumbers(&sessions, pins: pins)
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.dirName, $0.number) })
        }

        expect(numbers(["a", "b", "c"], pins: [:]), ["a": 1, "b": 2, "c": 3],
               "no pins: oldest first, one to three")
        expect(numbers(["a", "b", "c"], pins: ["b": 1]), ["b": 1, "a": 2, "c": 3],
               "a pin outranks start order")
        expect(numbers(["a", "b"], pins: ["gone": 1]), ["a": 2, "b": 3],
               "a pinned number is held while its project is away")
        // Same registry, so this pass sees what the one above left behind.
        expect(numbers(["a", "b", "c"], pins: ["gone": 1]), ["a": 2, "b": 3, "c": 4],
               "a new session does not renumber the tiles already up")

        let parsed = parse("""
        # 9 commented
        2 my-hub
        3\tfleet     # trailing comment
        12 too-high
        rubbish
        """)
        expect(parsed, ["my-hub": 2, "fleet": 3], "parse: comments, tabs and junk lines")

        print(failures == 0 ? "\nall ok" : "\n\(failures) FAILED")
        return failures
    }
}
