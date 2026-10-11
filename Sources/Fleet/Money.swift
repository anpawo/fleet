import Charts
import SwiftUI

/// What left the bank account, month by month, read off `~/.bnp/payments.csv`.
///
/// Fleet only draws it: a routine outside this repository reads the bank once a day and adds
/// the lines the file lacks. A login the bank refuses stops that routine until someone has
/// looked, so the block says how old its newest payment is rather than pass a stale month for
/// today's.
enum Money {
    static let file = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".bnp/payments.csv")

    /// What a payment was for. Nine: the export names eighteen categories, and eighteen
    /// percentages a month are a statement, not a glance. A colour belongs to its kind in
    /// every month; its place does not, a month ranks its own — so two colours a colour-blind
    /// eye confuses can sit side by side, and the name its arrow points to is what says which.
    enum Kind: CaseIterable {
        case food, transport, shopping, clothes, leisure, subscriptions, health, loan, other

        var title: String {
            switch self {
            case .food: "Food"
            case .transport: "Transport"
            case .shopping: "Shopping"
            case .clothes: "Clothes"
            case .leisure: "Leisure"
            case .subscriptions: "Subscriptions"
            case .health: "Health"
            case .loan: "Loan"
            case .other: "Other"
            }
        }

        /// Checked as a set against the block's green: lightness, 3:1 on the ground. Grey for
        /// what has no name of its own.
        var tint: Color {
            switch self {
            case .food: Color(red: 0.224, green: 0.529, blue: 0.898)
            case .transport: Color(red: 0.851, green: 0.349, blue: 0.149)
            case .shopping: Color(red: 0.098, green: 0.620, blue: 0.439)
            case .clothes: Color(red: 0.902, green: 0.404, blue: 0.404)
            case .leisure: Color(red: 0.565, green: 0.522, blue: 0.914)
            case .subscriptions: Color(red: 0.788, green: 0.522, blue: 0.0)
            case .health: Color(red: 0.110, green: 0.588, blue: 0.110)
            case .loan: Color(red: 0.835, green: 0.318, blue: 0.506)
            case .other: Color(white: 0.45)
            }
        }

        /// By the words of the export's own category, so a category it starts using tomorrow
        /// lands in Other instead of nowhere. Clothes are the exception: the export has them
        /// under Shopping, and only the bank's own code for the line (104) tells them apart.
        init(category: String, bankCode: String = "") {
            let name = category.lowercased()
            func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
            if has("loan") { self = .loan }
            else if has("subscription") { self = .subscriptions }
            else if has("cloth") || bankCode == "104" { self = .clothes }
            else if has("shopping", "tobacco") { self = .shopping }
            else if has("train", "uber", "taxi", "bus", "metro") { self = .transport }
            else if has("grocer", "restaurant", "food") { self = .food }
            else if has("bars", "leisure") { self = .leisure }
            else if has("health", "vet", "pharmac") { self = .health }
            else { self = .other }
        }
    }

    /// A slice's name beside the pie — see `Month.callouts`.
    struct Callout {
        let kind: Kind
        /// The middle of the slice, in turns clockwise from twelve o'clock.
        let turn: Double
        /// The name's height, down from the pie's centre.
        var y: Double
        var right: Bool { turn < 0.5 }
    }

    struct Month: Identifiable, Equatable {
        /// `2026-10`.
        let id: String
        var spent: [Kind: Double] = [:]
        var total: Double { spent.values.reduce(0, +) }

        /// Each kind's part of what was spent, in whole percent that add up to 100: rounded
        /// one by one they can come to 99 or 101. The points left over go to the kinds that
        /// lost the most to the rounding.
        var shares: [Kind: Int] {
            let total = total
            guard total > 0 else { return [:] }
            let exact = Kind.allCases.map { (kind: $0, share: 100 * (spent[$0] ?? 0) / total) }
            var shares = Dictionary(uniqueKeysWithValues: exact.map { ($0.kind, Int($0.share)) })
            let left = 100 - shares.values.reduce(0, +)
            let lost = exact.sorted { $0.share - $0.share.rounded(.down) > $1.share - $1.share.rounded(.down) }
            for entry in lost.prefix(max(0, left)) { shares[entry.kind, default: 0] += 1 }
            return shares
        }

        /// The kinds the month shows, the largest first; one that reads 0% is left out (asked
        /// 2026-10-11, the day there were nine and a short month had six noughts).
        var ranked: [Kind] {
            let shares = shares
            return Kind.allCases.filter { (shares[$0] ?? 0) > 0 }
                .sorted { (spent[$0] ?? 0) > (spent[$1] ?? 0) }
        }

        /// Where each slice's name goes: level with the middle of its rim, on its side of the
        /// pie. Two that would touch part the way the ranking runs — down the right side, up
        /// the left — so it is the small slices crowding twelve o'clock that give way; past
        /// `reach`, the room there is, the push comes back the other way.
        func callouts(radius: Double, line: Double, reach: Double) -> [Callout] {
            let kinds = ranked
            let whole = kinds.reduce(0) { $0 + (spent[$1] ?? 0) }
            var turned = 0.0
            var out = kinds.map { kind in
                let part = (spent[kind] ?? 0) / whole
                defer { turned += part }
                let turn = turned + part / 2
                return Callout(kind: kind, turn: turn, y: -radius * cos(2 * .pi * turn))
            }
            for right in [true, false] {
                let side = out.indices.filter { out[$0].right == right }
                let away = right ? 1.0 : -1.0
                for (before, index) in zip(side, side.dropFirst()) {
                    out[index].y = away * max(away * out[index].y, away * out[before].y + line)
                }
                guard let last = side.last, away * out[last].y > reach else { continue }
                out[last].y = away * reach
                for (after, index) in zip(side.reversed(), side.reversed().dropFirst()) {
                    out[index].y = away * min(away * out[index].y, away * out[after].y - line)
                }
            }
            return out
        }

        var name: String {
            let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
            guard let month = Int(id.suffix(2)), names.indices.contains(month - 1) else { return id }
            return names[month - 1]
        }
    }

    /// The months of an export, newest first, and the day of its newest line. Only a debit is
    /// spending — a credit is not money spent backwards — and not a debit that only moved to
    /// savings: it left the account without being spent.
    static func months(csv: String) -> (months: [Month], latest: String?) {
        var months: [String: Month] = [:]
        var latest: String?
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let row = fields(line, 7)
            guard row.count >= 3, row[0].count == 10, let amount = Double(row[1]), amount != 0 else { continue }
            latest = max(latest ?? row[0], row[0])
            guard amount < 0, !row[2].localizedCaseInsensitiveContains("saving") else { continue }
            let id = String(row[0].prefix(7))
            let kind = Kind(category: row[2], bankCode: row.count > 6 ? row[6] : "")
            months[id, default: Month(id: id)].spent[kind, default: 0] -= amount
        }
        return (months.values.sorted { $0.id > $1.id }, latest)
    }

    /// The first `count` fields of a CSV line. Quotes are honoured: "Restaurants, fast food &
    /// coffee" carries its own comma.
    static func fields(_ line: Substring, _ count: Int) -> [String] {
        var out: [String] = [], field = "", quoted = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                out.append(field)
                field = ""
                if out.count == count { return out }
            } else {
                field.append(character)
            }
        }
        return out + [field]
    }

    static func euros(_ amount: Double) -> String {
        "\(Int(amount.rounded()).formatted(.number.locale(Locale(identifier: "en_US")))) €"
    }

    /// `2026-10-02` as `2 Oct`.
    static func day(_ date: String) -> String {
        let month = Month(id: String(date.prefix(7))).name.capitalized
        return "\(Int(date.suffix(2)) ?? 0) \(month)"
    }
}

/// What the panel reads: the file, read again when it has been written and not before.
@MainActor
final class MoneyStore: ObservableObject {
    @Published private(set) var months: [Money.Month] = []
    @Published private(set) var latest: String?

    /// The real export, unless a picture of an invented one is being drawn — see
    /// `DemoFleet.fill`. Kept, so the next tick does not read the real one back over it.
    var file = Money.file { didSet { rereadIfWritten() } }
    private var written: Date?

    init() { rereadIfWritten() }

    func rereadIfWritten() {
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard date != written || date == nil else { return }
        written = date
        let read = (try? String(contentsOf: file, encoding: .utf8)).map(Money.months)
        months = read?.months ?? []
        latest = read?.latest
    }
}

/// What the month has cost so far: the figure on the heading and, unfolded, every month the
/// file holds.
///
/// Folded to its heading at rest, the month and its figure and nothing else (asked 2026-10-07,
/// with the name and the green). Unfolded — see `OpensUnderCommand` — the months newest first:
/// the question a figure raises is "against what", and last month is the answer.
///
/// A month is a block of its own and not a bar (asked 2026-10-07, the day the bars shipped):
/// a pie of what each kind took of it — see `MoneyMonth`.
struct MoneyColumn: View {
    @ObservedObject var store: MoneyStore
    var commandHeld = false
    /// Off for a render that draws no scroll view — see `CronColumn`.
    var scrolling = true
    /// The most the block takes of its column. Six months of pies are taller than a laptop's
    /// screen: they scroll under this rather than push TODO off the panel.
    var limit: CGFloat = .infinity

    /// Seeded from a flag so a render can show the open block, which only a pointer opens.
    @State private var open = CommandLine.arguments.contains("--money-open")
    /// Whether there are months below the block's lower edge from where it is scrolled.
    @State private var runsOn = false

    private static let shown = 6

    /// What the block costs around its months: the heading, the gap under it, the frame's own
    /// padding, and the line that dates the file.
    private static let chrome: CGFloat = 76

    var body: some View {
        let months = Array(store.months.prefix(Self.shown))
        let room = max(40, limit - Self.chrome)
        HubColumn(title: "SPENDING",
                  count: 0,
                  tint: BlockTint.money,
                  fill: BlockTint.money.darkened(0.48),
                  badge: months.first.map { "\($0.name) \(Money.euros($0.total))" },
                  topInset: 5,
                  collapsed: months.isEmpty || !open) {
            if scrolling {
                ScrollView(.vertical) { list(months) }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    // A month the edge cuts fades out, as CRONS's cards do: cut clean after
                    // its fourth line, it read as a month of four lines.
                    .onScrollGeometryChange(for: Bool.self) {
                        $0.contentOffset.y + $0.containerSize.height < $0.contentSize.height - 1
                    } action: { _, more in runsOn = more }
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            if runsOn {
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 36)
                            }
                        }
                    }
                    .frame(maxHeight: room)
            } else {
                list(months)
                    .frame(maxHeight: room, alignment: .top)
                    .clipped()
            }
            if let latest = store.latest {
                HubEmptyLine(text: "Last payment read: \(Money.day(latest))")
            }
        }
        .opens($open, underCommand: commandHeld)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ months: [Money.Month]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                if index > 0 { rule }
                MoneyMonth(month: month)
            }
        }
    }

    /// The rule CRONS parts its families with, and for its reason: a frame round a month is a
    /// block inside a block.
    private var rule: some View {
        Rectangle()
            .fill(.white.opacity(0.6))
            .frame(height: 1)
            .scaleEffect(x: 0.85)
            .padding(.vertical, 3)
    }
}

/// One month: its name and what it cost, and a pie of what each kind took of that (asked
/// 2026-10-11, in place of a grid of percentages and the month's largest payments: what was
/// paid where is not the question, how the month splits is).
///
/// The kinds are the month's own ranking — see `Month.ranked`: the pie turns from twelve
/// o'clock, the largest first. Each slice has an arrow out to its name and no legend beside
/// the pie (asked 2026-10-11, with the larger pie): the name is read where the slice is.
private struct MoneyMonth: View {
    let month: Money.Month

    private static let pie: CGFloat = 96
    /// The room over and under the pie, for a name pushed past its rim.
    private static let spill: CGFloat = 14
    /// From the rim to where the names start.
    private static let gap: CGFloat = 16

    var body: some View {
        let kinds = month.ranked
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(month.name)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(Money.euros(month.total))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
            // The arrow in the slice's colour, the name in the panel's own grey: the colour says
            // which, the text stays text.
            Canvas { context, size in
                let radius = Self.pie / 2
                let centre = CGPoint(x: size.width / 2, y: Self.spill + radius)
                for callout in month.callouts(radius: radius, line: 11.5, reach: radius + Self.spill - 6) {
                    let side: CGFloat = callout.right ? 1 : -1
                    let angle = 2 * .pi * callout.turn
                    let rim = CGPoint(x: centre.x + (radius + 1) * sin(angle),
                                      y: centre.y - (radius + 1) * cos(angle))
                    let tip = CGPoint(x: centre.x + side * (radius + Self.gap), y: centre.y + callout.y)
                    let back = atan2(rim.y - tip.y, rim.x - tip.x)
                    var arrow = Path()
                    arrow.move(to: rim)
                    arrow.addLine(to: tip)
                    for barb in [-0.5, 0.5] {
                        arrow.move(to: tip)
                        arrow.addLine(to: CGPoint(x: tip.x + 4 * cos(back + barb),
                                                  y: tip.y + 4 * sin(back + barb)))
                    }
                    context.stroke(arrow, with: .color(callout.kind.tint),
                                   style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    context.draw(Text(callout.kind.title)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.5)),
                                 at: CGPoint(x: tip.x + side * 4, y: tip.y),
                                 anchor: callout.right ? .leading : .trailing)
                }
            }
            .frame(height: Self.pie + 2 * Self.spill)
            .background(alignment: .top) {
                // The inset is the ground showing between two slices: neighbours change with
                // the month, and two close colours side by side still read as two.
                Chart(kinds, id: \.self) { kind in
                    SectorMark(angle: .value("Spent", month.spent[kind] ?? 0), angularInset: 1)
                        .foregroundStyle(kind.tint)
                }
                .frame(width: Self.pie, height: Self.pie)
                .padding(.top, Self.spill)
            }
        }
    }
}
