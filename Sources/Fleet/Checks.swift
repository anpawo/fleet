import Carbon.HIToolbox
import Foundation
import SwiftUI

/// One thing the hourly checker (`~/.claude/skills/checker`) watches or watched: still waiting (`<id>.json`), arrived
/// (`fired/`), or dropped (`fired/` with a `dropped` stamp: nothing watches it any more).
struct CheckEntry: Equatable {
    enum State: String { case waiting, dropped, arrived }

    let id: String
    let name: String
    let watching: String
    let state: State
    /// ms: when it began waiting, arrived or was dropped.
    let at: Double

    var detail: String {
        switch state {
        case .waiting: return "waiting since \(InboxView.when(at))"
        case .arrived: return "arrived \(InboxView.when(at))"
        case .dropped: return "dropped \(InboxView.when(at)) — nothing watches it"
        }
    }

    /// Waiting first, then dropped, then arrived, each newest first: a dropped watch must not hide behind old arrivals.
    static func load(state: URL) -> (entries: [CheckEntry], last: String) {
        func read(_ folder: URL) -> [[String: Any]] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }
                .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        }
        func entry(_ json: [String: Any]) -> CheckEntry? {
            guard let id = json["id"] as? String else { return nil }
            let what = json["what"] as? String ?? ""
            let name = json["name"] as? String ?? String(what.prefix(40))
            let watching = (json["chat"] as? String).map { "WhatsApp “\($0)”" }
                ?? (json["cmd"] != nil ? "command" : "Gmail")
            func stamp(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
            let fired = (json["fired"] as? [String: Any]).flatMap { stamp($0["at"]) }
            let (state, at): (State, Double?) = stamp(json["dropped"]).map { (.dropped, $0) }
                ?? fired.map { (.arrived, $0) } ?? (.waiting, stamp(json["since"]))
            return CheckEntry(id: id, name: name, watching: watching, state: state, at: at ?? 0)
        }
        let all = (read(state) + read(state.appending(path: "fired"))).compactMap(entry)
        let order: [State] = [.waiting, .dropped, .arrived]
        let entries = all.sorted {
            let (x, y) = (order.firstIndex(of: $0.state)!, order.firstIndex(of: $1.state)!)
            return x != y ? x < y : $0.at > $1.at
        }
        return (entries, lastRun(in: state.appending(path: "check.log")))
    }

    /// The newest summary line of the log, "2026-10-19 23:10:02  8 awaited, 0 arrived, 0 errors, 35 s", as "23h10 · 8 awaited, …".
    static func lastRun(in log: URL) -> String {
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        guard let line = lines.last(where: { $0.contains(" awaited, ") }), line.count > 21 else { return "no check recorded" }
        let parsed = DateFormatter()
        parsed.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let at = parsed.date(from: String(line.prefix(19))).map { InboxView.when($0.timeIntervalSince1970 * 1000) } ?? String(line.prefix(19))
        let counts = line.dropFirst(21).split(separator: ",").dropLast().joined(separator: ",")
        return "\(at) · \(counts)"
    }
}

/// S on Echo: every check the hourly watcher has, dropped ones marked.
struct ChecksView: View {
    @ObservedObject var inbox: Inbox
    static let shown = 18

    private static func colour(_ state: CheckEntry.State) -> Color {
        switch state {
        case .waiting: return Color(red: 0.40, green: 0.70, blue: 1.00)
        case .dropped: return Color(red: 1.00, green: 0.45, blue: 0.40)
        case .arrived: return Color(red: 0.24, green: 0.82, blue: 0.35)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Checks")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 22)
                .frame(height: 34)
                .background(Color(white: 94 / 255), in: Capsule())
            Text("Last check \(inbox.lastCheck)")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 22)
                .frame(height: 34)
                .background(Color(white: 94 / 255), in: Capsule())
            VStack(spacing: 3) {
                ForEach(inbox.checks.prefix(Self.shown), id: \.id) { row($0) }
                if inbox.checks.count > Self.shown {
                    Text("+ \(inbox.checks.count - Self.shown) arrived earlier").font(.system(size: 11)).opacity(0.6)
                }
            }
            KeyBubble(symbol: "gearshape", label: "back", off: false, tint: nil, icon: nil, pressed: inbox.pressed == kVK_ANSI_S) {
                _ = inbox.key(UInt16(kVK_ANSI_S))
            }
        }
        .fixedSize()
        .foregroundStyle(Color(white: 237 / 255))
        .padding(.top, Inbox.margin)
        .frame(width: Inbox.window.width, height: Inbox.settingsHeight, alignment: .top)
    }

    private func row(_ check: CheckEntry) -> some View {
        HStack(spacing: 14) {
            Text(check.state.rawValue.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Self.colour(check.state))
                .frame(width: 62, alignment: .leading)
            Text(check.name).font(.system(size: 13, weight: .semibold)).frame(width: 300, alignment: .leading)
            Text(check.watching).font(.system(size: 12)).opacity(0.7).frame(width: 130, alignment: .leading)
            Text(check.detail).font(.system(size: 12)).frame(width: 290, alignment: .leading)
        }
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(height: 24)
        .background(Color(white: 94 / 255).mix(with: check.state == .dropped ? Self.colour(.dropped) : .clear, by: 0.25), in: Capsule())
    }
}
