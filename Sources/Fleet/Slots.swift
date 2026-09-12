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
        # A project listed here takes its number whenever it is running, from whoever happens
        # to be wearing it — so ⌘3 is the same project every time it is up. While it is away
        # the number is nobody's: the next session along takes it, as they always have.
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
