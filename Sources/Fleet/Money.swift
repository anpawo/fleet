import SwiftUI

/// What left the bank account, month by month, read off `~/self/bnp/state/payments.csv`.
///
/// Fleet only draws it: a routine outside this repository reads the bank once a day and adds
/// the lines the file lacks. A login the bank refuses stops that routine until someone has
/// looked, so the block says how old its newest payment is rather than pass a stale month for
/// today's.
enum Money {
    static let file = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "self/bnp/state/payments.csv")

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
        /// How far past the rim its arrow runs, along the slice's own radius.
        var length: Double
        var right: Bool { turn < 0.5 }

        /// A point of that radius, from the pie's centre: `past` the rim, y down.
        func point(radius: Double, past: Double) -> (x: Double, y: Double) {
            ((radius + past) * sin(2 * .pi * turn), -(radius + past) * cos(2 * .pi * turn))
        }
    }

    /// Who pays a debit back, from `payback.json` beside the export: his own arrangement, kept
    /// out of this repository. A rule gives `share` of a debit (all of it, unless told) to `who`
    /// when its category or merchant holds `match`, from the day or month `from` and for a debit of
    /// `atLeast` that much; a debit takes the rules in order until it is all given.
    struct Rule: Decodable {
        let who: String
        let match: String
        let share: Double?
        let atLeast: Double?
        let from: String?
    }

    struct Month: Identifiable, Equatable {
        /// `2026-10`.
        let id: String
        /// What the month cost, by kind: its debits, less what somebody else paid of them. A
        /// loan's instalment and the transfer that covers it are money passing through the
        /// account, not spending (asked 2026-10-12): see `months`.
        var spent: [Kind: Double] = [:]
        /// What somebody pays back of the month's debits, by who: see `Rule`.
        var back: [String: Double] = [:]
        /// What came back into the account: the credits the bank files as refunds, its code
        /// 1209 (read off a card refund and a health insurer's; a transfer from a person, his
        /// parents' or his own included, is 1214).
        var refunds: Double = 0
        var total: Double { spent.values.reduce(0, +) }
        /// What is left of the month his own once all of that is in.
        var yours: Double { max(0, total - back.values.reduce(0, +) - refunds) }

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

        /// Where each shown kind's slice starts and ends, in turns clockwise from twelve o'clock.
        var slices: [(kind: Kind, from: Double, to: Double)] {
            let kinds = ranked
            let whole = kinds.reduce(0) { $0 + (spent[$1] ?? 0) }
            var turned = 0.0
            return kinds.map { kind in
                let from = turned
                turned += (spent[kind] ?? 0) / whole
                return (kind, from, turned)
            }
        }

        /// The kind whose slice is under a point, taken from the pie's centre, y down. Nil
        /// past the rim.
        func kind(at point: CGPoint, radius: Double) -> Kind? {
            guard hypot(point.x, point.y) <= radius else { return nil }
            let turn = (atan2(point.x, -point.y) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
            return slices.last { $0.from <= turn }?.kind
        }

        /// The arrow of each of `kinds`, the slices whose name is not inside them: straight out
        /// of the middle of its rim, along its own radius (asked 2026-10-12 — aimed at wherever
        /// its name had room, every arrow left the pie at an angle of its own). `reach` long,
        /// and longer for a name that would touch the one before it: a quarter of the pie at
        /// a time, from the horizontal towards twelve or six o'clock, where a longer arrow
        /// lifts a name clear — so the small slices crowding twelve o'clock stack up over the
        /// pie.
        ///
        /// ponytail: no arrow past `longest`, the room there is. Two slices under 4% side by
        /// side at three or nine o'clock would still touch; part them sideways if a month
        /// ever draws that.
        func callouts(of kinds: Set<Kind>, radius: Double, reach: Double, line: Double, longest: Double) -> [Callout] {
            var out = slices.filter { kinds.contains($0.kind) }
                .map { Callout(kind: $0.kind, turn: ($0.from + $0.to) / 2, length: reach) }
            func lift(_ index: Int) -> Double { abs(cos(2 * .pi * out[index].turn)) }
            for quarter in 0 ..< 4 {
                var floor = -Double.infinity
                for index in out.indices.filter({ min(3, Int(out[$0].turn * 4)) == quarter })
                    .sorted(by: { lift($0) < lift($1) }) {
                    if (radius + out[index].length) * lift(index) < floor + line {
                        out[index].length = min(longest, (floor + line) / lift(index) - radius)
                    }
                    floor = (radius + out[index].length) * lift(index)
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
    ///
    /// One credit does count, against a debit: a cover, by the word in its category ("loan
    /// instalment cover"), pays for the kind that category names, in its own month. That
    /// much of the kind is not spent; what a cover did not reach stays spent. In the newest
    /// month, a debit of a kind earlier months had covered is not spent either while its cover
    /// is not in: the month's figure would otherwise carry an instalment for the weeks its
    /// cover takes to come.
    static func months(csv: String, rules: [Rule] = []) -> (months: [Month], latest: String?) {
        var months: [String: Month] = [:]
        var covers: [String: [Kind: Double]] = [:]
        var refunds: [String: Double] = [:]
        var latest: String?
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let row = fields(line, 7)
            guard row.count >= 3, row[0].count == 10, let amount = Double(row[1]), amount != 0 else { continue }
            latest = max(latest ?? row[0], row[0])
            let id = String(row[0].prefix(7))
            let kind = Kind(category: row[2], bankCode: row.count > 6 ? row[6] : "")
            if amount > 0 {
                if row.count > 6, row[6] == "1209" { refunds[id, default: 0] += amount }
                guard row[2].localizedCaseInsensitiveContains("cover") else { continue }
                covers[id, default: [:]][kind, default: 0] += amount
            } else if !row[2].localizedCaseInsensitiveContains("saving") {
                months[id, default: Month(id: id)].spent[kind, default: 0] -= amount
                let named = row[2] + " " + (row.count > 3 ? row[3] : "")
                var left = 1.0
                for rule in rules where left > 0 && row[0] >= rule.from ?? "" && -amount >= rule.atLeast ?? 0
                    && named.localizedCaseInsensitiveContains(rule.match) {
                    let share = min(rule.share ?? 1, left)
                    months[id]?.back[rule.who, default: 0] -= amount * share
                    left -= share
                }
            }
        }
        let newest = months.keys.max()
        for id in months.keys {
            months[id]?.refunds = refunds[id] ?? 0
            for (kind, paid) in months[id]?.spent ?? [:] {
                let cover = min(paid, covers[id]?[kind] ?? 0)
                if cover > 0 {
                    months[id]?.spent[kind] = paid > cover ? paid - cover : nil
                } else if id == newest, covers.contains(where: { $0.key < id && $0.value[kind] != nil }) {
                    months[id]?.spent[kind] = nil
                }
            }
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

    /// How far from the pie's centre, along the middle of a slice, a label sits inside it on
    /// straight lines: `rows` are how wide they are, each `line` tall, one centred under the
    /// other. A place that keeps every line 2pt clear of the slice's sides and no corner of it
    /// further than `within` from the centre — 3pt short of the rim, unless told — and never
    /// over the centre: the furthest one out, or the one nearest `near` when that is given.
    /// Nil for a slice with no such place. Turns clockwise from twelve o'clock.
    static func seat(_ rows: [Double], line: Double, from: Double, to: Double, radius: Double,
                     within: Double? = nil, near: Double? = nil) -> Double? {
        let middle = Double.pi * (from + to), half = Double.pi * (to - from)
        let along = (x: sin(middle), y: -cos(middle))
        let top = -line * Double(rows.count) / 2
        let corners = rows.enumerated().flatMap { row, width in
            [-0.5, 0.5].flatMap { side in [0.0, 1].map { (x: side * width, y: top + (Double(row) + $0) * line) } }
        }
        let limit = within ?? radius - 3
        let tries = Array(stride(from: limit, through: max(0.2 * radius, (rows.max() ?? 0) / 2 + 2), by: -2))
        return (near.map { near in tries.sorted { abs($0 - near) < abs($1 - near) } } ?? tries).first { out in
            corners.allSatisfy { corner in
                let x = out * along.x + corner.x
                let y = out * along.y + corner.y
                let far = hypot(x, y)
                // The corner's angle off the slice's middle.
                let off = abs(atan2(x * along.y - y * along.x, x * along.x + y * along.y))
                return far <= limit && (half - off >= .pi / 2 || far * sin(half - off) >= 2)
            }
        }
    }

    /// How long a line may be along a slice's own arc, `out` from the pie's centre: the arc,
    /// less 3pt either side. Turns, as `Month.slices` gives them.
    static func arc(from: Double, to: Double, out: Double) -> Double {
        2 * .pi * (to - from) * out - 6
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
    private var written: [Date?] = []

    init() { rereadIfWritten() }

    func rereadIfWritten() {
        let files = [file, file.deletingLastPathComponent().appending(path: "payback.json")]
        let dates = files.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        guard dates != written || dates[0] == nil else { return }
        written = dates
        let rules = (try? Data(contentsOf: files[1])).flatMap { try? JSONDecoder().decode([Money.Rule].self, from: $0) }
        let read = (try? String(contentsOf: file, encoding: .utf8)).map { Money.months(csv: $0, rules: rules ?? []) }
        months = read?.months ?? []
        latest = read?.latest
    }
}

/// What the month has cost so far: the figure on the heading and, unfolded, the month itself.
///
/// Folded to its heading at rest, the month and its figure and nothing else (asked 2026-10-07,
/// with the name and the green). Unfolded by the pointer alone, no ⌘ (asked 2026-10-12), it is
/// as tall as the current month and shows that one. The month before is a scroll away — the
/// question a figure raises is "against what", and last month is the answer — and the earlier
/// ones wait behind a button under it.
///
/// A month is a block of its own and not a bar (asked 2026-10-07, the day the bars shipped):
/// a pie of what each kind took of it — see `MoneyMonth`.
struct MoneyColumn: View {
    @ObservedObject var store: MoneyStore
    /// Off for a render that draws no scroll view — see `CronColumn`.
    var scrolling = true
    /// The most the block takes of its column: a month taller than this scrolls under it
    /// rather than push TODO off the panel.
    var limit: CGFloat = .infinity

    /// Seeded from a flag so a render can show the open block, which only a pointer opens.
    @State private var open = CommandLine.arguments.contains("--money-open")
    /// Whether the block's lower edge cuts a month: scrolled off the top, and not at the end.
    @State private var runsOn = false
    /// How many months the list holds: `recent`, until the button is asked for more.
    @State private var shown = MoneyColumn.recent

    private static let recent = 2

    /// What the block costs around its months: the heading, the gap under it, the frame's own
    /// padding, and the line that dates the file.
    private static let chrome: CGFloat = 76

    var body: some View {
        let months = Array(store.months.prefix(shown))
        let room = max(40, limit - Self.chrome)
        HubColumn(title: "SPENDING",
                  count: 0,
                  tint: BlockTint.money,
                  fill: BlockTint.money.darkened(0.48),
                  badge: months.first.map { "\($0.name) \(Money.euros($0.total))" },
                  topInset: 5,
                  collapsed: months.isEmpty || !open) {
            if let current = months.first {
                if scrolling {
                    // The current month, not drawn, is what the block is measured by: the
                    // list scrolls in the room it takes.
                    MoneyMonth(month: current)
                        .hidden()
                        .frame(maxHeight: room, alignment: .top)
                        .overlay {
                            ScrollView(.vertical) { list(months) }
                                .scrollIndicators(.hidden)
                                .scrollBounceBehavior(.basedOnSize)
                                // A month the edge cuts fades out, as CRONS's cards do: cut
                                // clean after its fourth line, it read as a month of four
                                // lines. At rest it cuts none: the edge is the month's own.
                                .onScrollGeometryChange(for: Bool.self) {
                                    $0.contentOffset.y > 1
                                        && $0.contentOffset.y + $0.containerSize.height < $0.contentSize.height - 1
                                } action: { _, cut in runsOn = cut }
                                .mask {
                                    VStack(spacing: 0) {
                                        Rectangle()
                                        if runsOn {
                                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                                .frame(height: 36)
                                        }
                                    }
                                }
                        }
                } else {
                    MoneyMonth(month: current)
                        .frame(maxHeight: room, alignment: .top)
                        .clipped()
                }
            }
            if let latest = store.latest {
                HubEmptyLine(text: "Last payment read: \(Money.day(latest))")
            }
        }
        .onHover { inside in withAnimation(OverlayView.fold) { open = inside } }
        .onChange(of: open) { if !open { shown = Self.recent } }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ months: [Money.Month]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                if index > 0 { rule }
                MoneyMonth(month: month)
            }
            if store.months.count > shown {
                Button { shown += 3 } label: {
                    Text("Load more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .titleGround()
                        // The chip's ground hangs past its words, and the scroll view cuts
                        // what hangs past its own edge.
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
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
/// o'clock, the largest first. A slice's name is written inside it, as near the rim as it
/// fits, over what the slice came to in euros (asked 2026-10-12, with the pie at 248 pt): on
/// straight lines wherever the slice has room for them — see `Money.seat` — and along its
/// own rim where it has not (asked 2026-10-12, after a pie whose names all bent round it).
/// One too thin for either has an arrow out to them, and there is no legend beside the pie
/// (asked 2026-10-11): the name is still read where the slice is.
///
/// A slice's share is written at rest (asked 2026-10-12, after an hour of one that came under
/// the pointer only), as near the middle of the slice as it fits and nearer the centre than
/// the name. In the name's own size: all of them show at once, and 11pt filled a thin slice
/// from side to side.
///
/// The month's name and its total are on the line the pie's top stands in, either side of it
/// (asked 2026-10-12): a circle leaves the ends of that line alone.
///
/// The slice under the pointer gets a thin bright edge and nothing else (asked 2026-10-12,
/// after it was raised past the rim). The edge is inside the slice — see `Wedge`: drawn on
/// the slice's outline it lay over the ground either side, unevenly (asked 2026-10-12).
private struct MoneyMonth: View {
    let month: Money.Month

    @State private var hovered: Money.Kind?
    /// How wide the month is drawn: what a name beside the pie has to fit in.
    @State private var width: Double = 288

    /// The pie's radius: the first of these that leaves every name past the rim its room. A
    /// thin slice at nine o'clock is the one that asks for a smaller pie — its rim is too
    /// short for its name, and the pie at its largest leaves nothing beside it.
    private static let radii: [Double] = [124, 112, 100, 88, 76, 64]
    /// How far past the rim an arrow runs, and the most it is stretched to part two names.
    private static let reach: CGFloat = 16
    private static let longest: CGFloat = 90
    /// From the middle of a line of text to the middle of the one under it.
    private static let pitch: CGFloat = 11
    /// What the month's name and its total take of the top. The pie may stand in it; a name
    /// past the rim may not, it would read as one more word of that line.
    private static let heading: CGFloat = 16
    /// How far inside the rim a slice's name is written, and what it came to under it.
    private static let nameIn: Double = 9
    private static let priceIn: Double = 20

    /// Where a slice's name and what it came to are written.
    private enum Spot {
        /// On straight lines inside the slice, that far from the pie's centre along its middle.
        case straight(Double)
        /// Along the slice's own rim: no room for straight lines, and a rim long enough.
        case rim
        /// Past the rim, on an arrow.
        case past
    }

    private struct Placed {
        let kind: Money.Kind
        let turn: Double
        let percent: String
        let price: String
        let spot: Spot
        /// How wide it is past the rim, with the share beside the price.
        let width: Double
        /// Where the share is written, that far from the centre: on a straight line, or
        /// `round` an arc where the slice has no room for one. Nil for a sliver, whose share
        /// goes beside its price.
        let share: (out: Double, round: Bool)?
    }

    private static func width(_ text: String, _ font: NSFont) -> Double {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Where a name past the rim is drawn: just past the tip of its arrow, which points at the
    /// middle of its two lines (asked 2026-10-14 — written beside the tip, the lines stood
    /// either side of it). From the pie's centre, y down, with where the tip meets the lines
    /// across them, 0 at their left edge: each line is drawn from that point.
    ///
    /// ponytail: `Month.callouts` parts the tips, not the lines. A wide name near three or
    /// nine o'clock under a narrow one could come a few points closer than it; part the lines
    /// themselves if a month ever draws that.
    private func spot(_ callout: Money.Callout, in labels: [Placed], radius: Double) -> (x: Double, y: Double, across: Double) {
        let width = labels.first { $0.kind == callout.kind }?.width ?? 0
        let tip = callout.point(radius: radius, past: callout.length)
        let way = (x: sin(2 * .pi * callout.turn), y: -cos(2 * .pi * callout.turn))
        // From the middle of the lines out to their edge, back along the arrow; their ink is
        // a point short of their line boxes, top and bottom.
        let edge = min(width / 2 / abs(way.x), (Self.pitch - 1) / abs(way.y))
        let out = edge + 3
        return (tip.x + out * way.x, tip.y + out * way.y, 0.5 - way.x * edge / max(width, 1))
    }

    /// Where the labels go for a pie of that radius, and whether the ones past the rim all
    /// have their room beside it.
    private func plan(radius: Double) -> (labels: [Placed], callouts: [Money.Callout], fits: Bool) {
        let shares = month.shares
        let labels = month.slices.map { slice in
            let percent = "\(shares[slice.kind] ?? 0)%", price = Money.euros(month.spent[slice.kind] ?? 0)
            let name = Self.width(slice.kind.title, .systemFont(ofSize: 9))
            let cost = Self.width(price, .monospacedDigitSystemFont(ofSize: 9, weight: .medium))
            let share = Self.width(percent, .monospacedDigitSystemFont(ofSize: 9, weight: .semibold))
            let turn = (slice.from + slice.to) / 2
            let room = { (out: Double) in Money.arc(from: slice.from, to: slice.to, out: out) }
            let seat = { (rows: [Double], line: Double, within: Double?, near: Double?) in
                Money.seat(rows, line: line, from: slice.from, to: slice.to, radius: radius,
                           within: within, near: near)
            }
            // A line as tall as its ink, not as its line box: 1.5pt less.
            let line = Self.pitch - 1.5
            let spot: Spot
            // How far out a corner of the share may be: 2pt short of the name's own lines.
            let limit: Double
            if let out = seat([name, cost], line, nil, nil) {
                spot = .straight(out)
                limit = hypot(max(abs(out * sin(2 * .pi * turn)) - max(name, cost) / 2, 0),
                              max(abs(out * cos(2 * .pi * turn)) - line, 0)) - 2
            } else if name <= room(radius - Self.nameIn), cost <= room(radius - Self.priceIn) {
                spot = .rim
                limit = radius - Self.priceIn - 7
            } else {
                spot = .past
                limit = radius - 3
            }
            let round = stride(from: 0.58 * radius, through: limit - 6, by: 4).first { share <= room($0) }
            var past = false
            if case .past = spot { past = true }
            // ponytail: a share its slice has no room for under the name is written there all
            // the same, a point or two over the sides. Make it smaller if a month draws that.
            return Placed(kind: slice.kind, turn: turn, percent: percent, price: price, spot: spot,
                          width: max(name, Self.width("\(percent) \(price)",
                                                      .monospacedDigitSystemFont(ofSize: 9, weight: .semibold))),
                          share: seat([share], line, limit, radius / 2).map { ($0, false) }
                              ?? (round ?? (past ? nil : limit - 6)).map { ($0, true) })
        }
        // Two lines and a little air: packed, six names read as one column of twelve lines.
        let outside = labels.filter { if case .past = $0.spot { true } else { false } }
        let callouts = month.callouts(of: Set(outside.map(\.kind)), radius: radius,
                                      reach: Self.reach, line: 2 * Self.pitch + 3, longest: Self.longest)
        let fits = callouts.allSatisfy { callout in
            let label = labels.first { $0.kind == callout.kind }?.width ?? 0
            // 3pt over: the edge pushes the name that much towards the pie.
            return abs(spot(callout, in: labels, radius: radius).x) + label / 2 <= width / 2 + 3
        }
        return (labels, callouts, fits)
    }

    var body: some View {
        let radius = Self.radii.first { plan(radius: $0).fits } ?? Self.radii[Self.radii.count - 1]
        let (labels, callouts, _) = plan(radius: radius)
        // The room over and under the pie is what the names past its rim take, and no more.
        let names = callouts.map { spot($0, in: labels, radius: radius).y }
        let bare = radius + 3
        let over = max(bare, Self.heading + Self.pitch + 2.75 - (names.min() ?? .infinity))
        let under = max(bare, Self.pitch + 2.75 + (names.max() ?? -.infinity))
        VStack(alignment: .leading, spacing: 6) {
            // The arrow in the slice's colour, the name in the panel's own grey: the colour says
            // which, the text stays text.
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: over)
                for label in labels {
                    let lit = hovered == label.kind
                    let digits = Font.system(size: 9, weight: .medium).monospacedDigit()
                    // Dark on the slice's own colour: against every one of the nine it reads
                    // better than white does.
                    let name = Text(label.kind.title).font(.system(size: 9))
                    let price = Text(label.price).font(digits)
                    func along(_ out: Double) -> CGPoint {
                        CGPoint(x: centre.x + out * sin(2 * .pi * label.turn),
                                y: centre.y - out * cos(2 * .pi * label.turn))
                    }
                    if let share = label.share {
                        let bold = Font.system(size: 9, weight: .semibold).monospacedDigit()
                        let ink = Color.black.opacity(lit ? 0.95 : 0.75)
                        if share.round {
                            Self.write(label.percent, bold, ink,
                                       in: context, round: centre, radius: share.out, turn: label.turn)
                        } else {
                            context.draw(Text(label.percent).font(bold).foregroundStyle(ink), at: along(share.out))
                        }
                    }
                    switch label.spot {
                    case .straight(let out):
                        let middle = along(out)
                        context.draw(name.foregroundStyle(.black.opacity(lit ? 0.95 : 0.75)),
                                     at: CGPoint(x: middle.x, y: middle.y - Self.pitch / 2))
                        context.draw(price.foregroundStyle(.black.opacity(0.65)),
                                     at: CGPoint(x: middle.x, y: middle.y + Self.pitch / 2))
                    case .rim:
                        Self.write(label.kind.title, .system(size: 9), .black.opacity(lit ? 0.95 : 0.75),
                                   in: context, round: centre, radius: radius - Self.nameIn, turn: label.turn)
                        Self.write(label.price, digits, .black.opacity(0.65),
                                   in: context, round: centre, radius: radius - Self.priceIn, turn: label.turn)
                    case .past:
                        guard let callout = callouts.first(where: { $0.kind == label.kind }) else { continue }
                        let percent = Text(label.share == nil ? label.percent + " " : "")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        func at(_ past: Double) -> CGPoint {
                            let point = callout.point(radius: radius, past: past)
                            return CGPoint(x: centre.x + point.x, y: centre.y + point.y)
                        }
                        let tip = at(callout.length)
                        let back = atan2(centre.y - tip.y, centre.x - tip.x)
                        var arrow = Path()
                        arrow.move(to: at(1))
                        arrow.addLine(to: tip)
                        for barb in [-0.5, 0.5] {
                            arrow.move(to: tip)
                            arrow.addLine(to: CGPoint(x: tip.x + 4 * cos(back + barb),
                                                      y: tip.y + 4 * sin(back + barb)))
                        }
                        context.stroke(arrow, with: .color(callout.kind.tint),
                                       style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        // ponytail: a name the edge would still cut round the smallest pie is
                        // held inside it, over its own arrow. Give `radii` a smaller one if a
                        // month ever draws that.
                        let spot = spot(callout, in: labels, radius: radius)
                        let left = min(max(centre.x + spot.x - label.width / 2, 0), size.width - label.width)
                        let x = left + spot.across * label.width, y = centre.y + spot.y
                        let anchor = UnitPoint(x: spot.across, y: 0.5)
                        context.draw(name.foregroundStyle(.white.opacity(lit ? 0.95 : 0.5)),
                                     at: CGPoint(x: x, y: y - Self.pitch / 2), anchor: anchor)
                        context.draw(percent.foregroundStyle(.white.opacity(0.85))
                                         + price.foregroundStyle(.white.opacity(0.75)),
                                     at: CGPoint(x: x, y: y + Self.pitch / 2), anchor: anchor)
                    }
                }
            }
            .frame(height: over + under)
            .background(alignment: .top) {
                ZStack {
                    ForEach(month.slices, id: \.kind) { slice in
                        let wedge = Wedge(from: slice.from, to: slice.to)
                        wedge.fill(slice.kind.tint)
                        // The edge the pointer lights: the inner half of a 2pt line, so it is
                        // the slice's own and the ground between two slices stays ground.
                        wedge.stroke(.white.opacity(0.7), lineWidth: 2)
                            .clipShape(wedge)
                            .opacity(hovered == slice.kind ? 1 : 0)
                    }
                }
                .frame(width: 2 * radius, height: 2 * radius)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .padding(.top, over - radius)
            }
            .overlay(alignment: .top) {
                HStack {
                    Text(month.name)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(Money.euros(month.total))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .overlay(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 2 * radius, height: 2 * radius)
                    .onContinuousHover { phase in
                        if case .active(let point) = phase {
                            hovered = month.kind(at: CGPoint(x: point.x - radius, y: point.y - radius), radius: radius)
                        } else {
                            hovered = nil
                        }
                    }
                    .padding(.top, over - radius)
            }
            if !month.back.isEmpty || month.refunds > 0 {
                line("arrow.uturn.backward", "Back", month.back.sorted { $0.value > $1.value }
                     + (month.refunds > 0 ? [("Refunds", month.refunds)] : []))
                line("equal", "Yours", [("", month.yours)], "once it is all back")
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
    }

    /// Writes `text` round the pie, `radius` from `centre`, its middle at `turn`: letter by
    /// letter, each standing on the circle. Clockwise with its head outwards over the upper
    /// half of the pie; the other way round under it, where that would be upside down.
    private static func write(_ text: String, _ font: Font, _ colour: Color, in context: GraphicsContext,
                              round centre: CGPoint, radius: Double, turn: Double) {
        let letters = text.map { context.resolve(Text(String($0)).font(font).foregroundStyle(colour)) }
        let widths = letters.map { $0.measure(in: CGSize(width: 99, height: 99)).width }
        let under = turn > 0.25 && turn < 0.75
        let way: Double = under ? -1 : 1
        var angle = 2 * .pi * turn - way * widths.reduce(0, +) / 2 / radius
        for (letter, width) in zip(letters, widths) {
            angle += way * width / 2 / radius
            var spot = context
            spot.translateBy(x: centre.x + radius * sin(angle), y: centre.y - radius * cos(angle))
            spot.rotate(by: .radians(angle + (under ? .pi : 0)))
            spot.draw(letter, at: .zero)
            angle += way * width / 2 / radius
        }
    }

    /// A slice as it is drawn: each side moved in by a point, parallel to itself, so the
    /// ground shows between two slices as a line of one width from the centre to the rim —
    /// neighbours change with the month, and two close colours side by side still read as
    /// two. Turns clockwise from twelve o'clock, as `Month.slices` gives them.
    private struct Wedge: Shape {
        let from: Double
        let to: Double

        func path(in rect: CGRect) -> Path {
            // A month of one kind is a disc: a wedge of a whole turn would draw its seam.
            guard to - from < 1 else { return Path(ellipseIn: rect) }
            let centre = CGPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2
            let half = Double.pi * (to - from), middle = Double.pi * (from + to) - .pi / 2
            // Where the two moved sides meet, along the slice's middle, and the angle each
            // loses at the rim.
            let tip = 1 / sin(half), lean = asin(1 / radius)
            // Nothing left of a slice thinner than the line, and no line in a slice that is
            // all but the whole pie.
            guard tip < radius else { return half > .pi / 2 ? Path(ellipseIn: rect) : Path() }
            var path = Path()
            path.move(to: CGPoint(x: centre.x + tip * cos(middle), y: centre.y + tip * sin(middle)))
            path.addArc(center: centre, radius: radius,
                        startAngle: .radians(2 * .pi * from - .pi / 2 + lean),
                        endAngle: .radians(2 * .pi * to - .pi / 2 - lean), clockwise: false)
            path.closeSubpath()
            return path
        }
    }

    /// What comes back of the month, under the pie and no slice of it: the pie is what was
    /// paid (asked 2026-10-25, in place of the loan's line, the month's figure being more than
    /// his own). Two lines, not one a payer: the block is as tall as its column lets it be, and
    /// four lines left the last under its edge.
    private func line(_ symbol: String, _ lead: String, _ amounts: [(String, Double)], _ note: String = "") -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(lead)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
            ForEach(amounts, id: \.0) { title, amount in
                HStack(spacing: 4) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(Money.euros(amount))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .lineLimit(1)
    }
}
