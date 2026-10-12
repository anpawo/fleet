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
        /// How far past the rim its arrow runs, along the slice's own radius.
        var length: Double
        var right: Bool { turn < 0.5 }

        /// A point of that radius, from the pie's centre: `past` the rim, y down.
        func point(radius: Double, past: Double) -> (x: Double, y: Double) {
            ((radius + past) * sin(2 * .pi * turn), -(radius + past) * cos(2 * .pi * turn))
        }
    }

    struct Month: Identifiable, Equatable {
        /// `2026-10`.
        let id: String
        /// What the month cost, by kind: its debits, less what somebody else paid of them.
        var spent: [Kind: Double] = [:]
        /// What a credit sent for the purpose paid of the month's debits, by kind. A loan's
        /// instalment and the transfer that covers it are money passing through the account,
        /// not spending (asked 2026-10-12) — see `months`.
        var covered: [Kind: Double] = [:]
        /// In the newest month only: a debit of a kind earlier months had covered, whose own
        /// cover is not in yet. Kept out of `spent` meanwhile: the month's figure would
        /// otherwise carry an instalment for the weeks its cover takes to come.
        var awaited: [Kind: Double] = [:]
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
    /// much of the kind is `covered` and not spent; what a cover did not reach stays spent.
    static func months(csv: String) -> (months: [Month], latest: String?) {
        var months: [String: Month] = [:]
        var covers: [String: [Kind: Double]] = [:]
        var latest: String?
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let row = fields(line, 7)
            guard row.count >= 3, row[0].count == 10, let amount = Double(row[1]), amount != 0 else { continue }
            latest = max(latest ?? row[0], row[0])
            let id = String(row[0].prefix(7))
            let kind = Kind(category: row[2], bankCode: row.count > 6 ? row[6] : "")
            if amount > 0 {
                guard row[2].localizedCaseInsensitiveContains("cover") else { continue }
                covers[id, default: [:]][kind, default: 0] += amount
            } else if !row[2].localizedCaseInsensitiveContains("saving") {
                months[id, default: Month(id: id)].spent[kind, default: 0] -= amount
            }
        }
        let newest = months.keys.max()
        for id in months.keys {
            for (kind, paid) in months[id]?.spent ?? [:] {
                let cover = min(paid, covers[id]?[kind] ?? 0)
                if cover > 0 {
                    months[id]?.covered[kind] = cover
                    months[id]?.spent[kind] = paid > cover ? paid - cover : nil
                } else if id == newest, covers.contains(where: { $0.key < id && $0.value[kind] != nil }) {
                    months[id]?.awaited[kind] = paid
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
/// o'clock, the largest first. A slice's name is written along its own rim, and under it what
/// it came to in euros, when the rim is long enough for them (asked 2026-10-12, with the pie
/// at 248 pt). One too thin has an arrow out to them, and there is no legend beside the pie
/// (asked 2026-10-11): the name is still read where the slice is.
///
/// A slice's share is not written at rest, its size says it. It comes under the pointer,
/// along an arc near the slice's middle (asked 2026-10-12).
///
/// The month's name and its total are on the line the pie's top stands in, either side of it
/// (asked 2026-10-12): a circle leaves the ends of that line alone.
///
/// The slice under the pointer is raised — see `Raised`.
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

    /// A slice's name and what it came to, and where they are written: along the slice's own
    /// rim, or past it on an arrow when the rim is too short for them.
    private struct Placed {
        let kind: Money.Kind
        let turn: Double
        let percent: String
        let price: String
        let inside: Bool
        /// How wide it is past the rim, with the share that joins the price under the pointer.
        let width: Double
        /// How far from the centre the share is written under the pointer: as near the
        /// slice's middle as the slice is wide enough for it. Nil for a sliver, whose share
        /// goes beside its price.
        let middle: Double?
    }

    private static func width(_ text: String, _ font: NSFont) -> Double {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Where the labels go for a pie of that radius, and whether the ones past the rim all
    /// have their room beside it.
    private func plan(radius: Double) -> (labels: [Placed], callouts: [Money.Callout], fits: Bool) {
        let shares = month.shares
        let labels = month.slices.map { slice in
            let percent = "\(shares[slice.kind] ?? 0)%", price = Money.euros(month.spent[slice.kind] ?? 0)
            let name = Self.width(slice.kind.title, .systemFont(ofSize: 9))
            let room = { (out: Double) in Money.arc(from: slice.from, to: slice.to, out: out) }
            let share = Self.width(percent, .monospacedDigitSystemFont(ofSize: 13, weight: .semibold))
            return Placed(kind: slice.kind, turn: (slice.from + slice.to) / 2, percent: percent, price: price,
                          inside: name <= room(radius - Self.nameIn)
                              && Self.width(price, .monospacedDigitSystemFont(ofSize: 9, weight: .medium))
                              <= room(radius - Self.priceIn),
                          width: max(name, Self.width("\(percent) \(price)",
                                                      .monospacedDigitSystemFont(ofSize: 9, weight: .semibold))),
                          middle: stride(from: 0.58 * radius, through: radius - 34, by: 4).first { share <= room($0) })
        }
        // Two lines and a little air: packed, six names read as one column of twelve lines.
        let callouts = month.callouts(of: Set(labels.filter { !$0.inside }.map(\.kind)), radius: radius,
                                      reach: Self.reach, line: 2 * Self.pitch + 3, longest: Self.longest)
        let fits = callouts.allSatisfy { callout in
            let label = labels.first { $0.kind == callout.kind }?.width ?? 0
            // 3pt over is taken off the gap between the arrow and the name.
            return abs(callout.point(radius: radius, past: callout.length).x) + 4 + label <= width / 2 + 3
        }
        return (labels, callouts, fits)
    }

    var body: some View {
        let kinds = month.ranked
        let radius = Self.radii.first { plan(radius: $0).fits } ?? Self.radii[Self.radii.count - 1]
        let (labels, callouts, _) = plan(radius: radius)
        // The room over and under the pie is what the names past its rim take, and no more —
        // and no less than a raised slice does.
        let tips = callouts.map { $0.point(radius: radius, past: $0.length).y }
        let bare = radius + Raised.rise + 3
        let over = max(bare, Self.heading + Self.pitch + 2.75 - (tips.min() ?? .infinity))
        let under = max(bare, Self.pitch + 2.75 + (tips.max() ?? -.infinity))
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
                    let middle = lit ? label.middle ?? (label.inside ? radius - 34 : nil) : nil
                    if let middle {
                        Self.write(label.percent, .system(size: 13, weight: .semibold).monospacedDigit(),
                                   .black.opacity(0.85), in: context, round: centre, radius: middle, turn: label.turn)
                    }
                    if label.inside {
                        Self.write(label.kind.title, .system(size: 9), .black.opacity(lit ? 0.95 : 0.75),
                                   in: context, round: centre, radius: radius - Self.nameIn, turn: label.turn)
                        Self.write(label.price, digits, .black.opacity(0.65),
                                   in: context, round: centre, radius: radius - Self.priceIn, turn: label.turn)
                    } else if let callout = callouts.first(where: { $0.kind == label.kind }) {
                        let name = Text(label.kind.title).font(.system(size: 9))
                        let percent = Text(lit && middle == nil ? label.percent + " " : "")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        let price = Text(label.price).font(digits)
                        func at(_ past: Double) -> CGPoint {
                            let point = callout.point(radius: radius, past: past)
                            return CGPoint(x: centre.x + point.x, y: centre.y + point.y)
                        }
                        let tip = at(callout.length)
                        let back = atan2(centre.y - tip.y, centre.x - tip.x)
                        var arrow = Path()
                        // From past the raised slice's edge, which the arrow would notch.
                        arrow.move(to: at(lit ? Raised.rise + 3 : 1))
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
                        let x = callout.right ? min(tip.x + 4, size.width - label.width) : max(tip.x - 4, label.width)
                        let anchor: UnitPoint = callout.right ? .leading : .trailing
                        context.draw(name.foregroundStyle(.white.opacity(lit ? 0.95 : 0.5)),
                                     at: CGPoint(x: x, y: tip.y - Self.pitch / 2), anchor: anchor)
                        context.draw(percent.foregroundStyle(.white.opacity(0.85))
                                         + price.foregroundStyle(.white.opacity(0.75)),
                                     at: CGPoint(x: x, y: tip.y + Self.pitch / 2), anchor: anchor)
                    }
                }
            }
            .frame(height: over + under)
            .background(alignment: .top) {
                ZStack {
                    // The inset is the ground showing between two slices: neighbours change with
                    // the month, and two close colours side by side still read as two.
                    Chart(kinds, id: \.self) { kind in
                        SectorMark(angle: .value("Spent", month.spent[kind] ?? 0), angularInset: 1)
                            .foregroundStyle(kind.tint)
                    }
                    ForEach(month.slices, id: \.kind) { slice in
                        Raised(from: slice.from, to: slice.to, tint: slice.kind.tint,
                               lift: hovered == slice.kind ? 1 : 0)
                    }
                }
                .frame(width: 2 * radius, height: 2 * radius)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: hovered)
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
            ForEach(Money.Kind.allCases.filter { month.covered[$0] != nil || month.awaited[$0] != nil },
                    id: \.self) { kind in through(kind) }
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

    /// A slice as the pointer raises it (asked 2026-10-12): drawn over the pie, `lift` of the
    /// way past the rim and over its neighbours either side, with a bright edge.
    ///
    /// A view that is handed every frame's own `lift`, so the slice is seen to grow (asked
    /// 2026-10-12): as a copy fading in over 150 ms it was only seen to light up. Solid from
    /// the first sixth of the move for the same reason.
    private struct Raised: View, Animatable {
        let from: Double
        let to: Double
        let tint: Color
        var lift: Double

        /// A little less than the 8 and 3 it had at first (asked 2026-10-12).
        static let rise: Double = 5
        static let spread: Double = 2

        var animatableData: Double {
            get { lift }
            set { lift = newValue }
        }

        var body: some View {
            Wedge(from: from, to: to, rise: Self.rise * lift, spread: Self.spread * lift)
                .fill(tint)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                .opacity(min(1, max(0, lift * 6)))
        }
    }

    /// Turns clockwise from twelve o'clock, as `Month.slices` gives them; `rise` past the
    /// frame's own circle, and `spread` wider at the rim either side.
    private struct Wedge: Shape {
        let from: Double
        let to: Double
        let rise: Double
        let spread: Double

        func path(in rect: CGRect) -> Path {
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 + rise
            // A month of one kind is a disc: a wedge of a whole turn would draw its seam.
            guard to - from < 1 else {
                return Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                              width: 2 * radius, height: 2 * radius))
            }
            let wider = spread / radius
            var path = Path()
            path.move(to: centre)
            path.addArc(center: centre, radius: radius,
                        startAngle: .radians(2 * .pi * from - .pi / 2 - wider),
                        endAngle: .radians(2 * .pi * to - .pi / 2 + wider), clockwise: false)
            path.closeSubpath()
            return path
        }
    }

    /// What went through the account without being the month's own: a debit somebody else's
    /// transfer paid. Under the pie and no slice of it — it is no part of what the month
    /// cost — and one line, so that the instalment has not simply vanished.
    private func through(_ kind: Money.Kind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(kind.title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            Text(Money.euros(month.covered[kind] ?? month.awaited[kind] ?? 0))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            Text(month.covered[kind] != nil ? "covered, not counted" : "cover awaited, not counted")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
        .lineLimit(1)
    }
}
