import SwiftUI

/// What left the bank account, month by month, read off `~/.bnp/payments.csv`.
///
/// Fleet only draws it. The bank has no API a routine can log in to — the login is a virtual
/// keypad and a phone approval — so the file is written by whoever last had a live session,
/// and the block says how old its newest payment is rather than pass a stale month for today's.
enum Money {
    static let file = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".bnp/payments.csv")

    /// What a payment was for. Nine: the export names eighteen categories, and eighteen
    /// percentages a month are a statement, not a glance. A colour belongs to its kind in
    /// every month; its place does not, a month ranks its own — so two colours a colour-blind
    /// eye confuses can sit side by side, and the name beside the dot is what says which.
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

    /// What a month paid to one place, or got from it: every line of the export that has the
    /// same name, kind and direction, as one. A credit has no kind: it was not spent on anything.
    struct Payment: Equatable {
        /// `2026-10-02`, the newest of them.
        let date: String
        /// Negative when it left the account.
        let amount: Double
        let kind: Kind?
        let name: String
        /// How many lines of the export it stands for.
        var count = 1
    }

    /// What makes two lines of the export one `Payment`.
    private struct Place: Hashable {
        let name: String
        let kind: Kind?
        let credit: Bool
    }

    struct Month: Identifiable, Equatable {
        /// `2026-10`.
        let id: String
        var spent: [Kind: Double] = [:]
        /// A line a place (asked 2026-10-11: twenty stops at one shop were twenty lines), credits
        /// too, the largest first whichever way it went.
        var payments: [Payment] = []
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

        var name: String {
            let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
            guard let month = Int(id.suffix(2)), names.indices.contains(month - 1) else { return id }
            return names[month - 1]
        }
    }

    /// The months of an export, newest first, and the day of its newest line. Only a debit is
    /// spending — a credit is not money spent backwards — but every line is kept, a place's
    /// lines as one, for the list of the largest.
    static func months(csv: String) -> (months: [Month], latest: String?) {
        var months: [String: Month] = [:]
        var latest: String?
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let row = fields(line, 7)
            guard row.count >= 3, row[0].count == 10, let amount = Double(row[1]), amount != 0 else { continue }
            let id = String(row[0].prefix(7))
            let kind = amount < 0 ? Kind(category: row[2], bankCode: row.count > 6 ? row[6] : "") : nil
            if let kind { months[id, default: Month(id: id)].spent[kind, default: 0] -= amount }
            // The bank's wording for a loan instalment is the contract's number, and that is
            // what the export has for its merchant: the category says what the line is. It
            // does for a credit too — Salary, not the name of who pays it.
            let named = row.count > 3 && amount < 0 && kind != .loan
            months[id, default: Month(id: id)].payments.append(
                Payment(date: row[0], amount: amount, kind: kind, name: named ? row[3] : row[2]))
            latest = max(latest ?? row[0], row[0])
        }
        for id in months.keys {
            let places = Dictionary(grouping: months[id]?.payments ?? []) {
                Place(name: $0.name, kind: $0.kind, credit: $0.amount > 0)
            }
            months[id]?.payments = places.map { place, lines in
                Payment(date: lines.map(\.date).max() ?? "", amount: lines.reduce(0) { $0 + $1.amount },
                        kind: place.kind, name: place.name, count: lines.count)
            }.sorted { (abs($0.amount), $0.date, $0.name) > (abs($1.amount), $1.date, $1.name) }
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

    private var written: Date?

    init() { rereadIfWritten() }

    func rereadIfWritten(_ file: URL = Money.file) {
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
/// what each kind took of it in percent, then its ten largest lines whichever way the money
/// went.
struct MoneyColumn: View {
    @ObservedObject var store: MoneyStore
    var commandHeld = false
    /// Off for a render that draws no scroll view — see `CronColumn`.
    var scrolling = true
    /// The most the block takes of its column. Four months of ten lines are taller than a
    /// laptop's screen: they scroll under this rather than push TODO off the panel.
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

/// One month: its name and what it cost, what each kind took of that, and its largest lines.
///
/// The kinds are the month's own ranking — see `Month.ranked` — not nine fixed places: the same
/// kind is not in the same cell from one month to the next.
private struct MoneyMonth: View {
    let month: Money.Month

    private static let largest = 10
    private static let columns = 3

    var body: some View {
        let kinds = month.ranked
        let shares = month.shares
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
            VStack(spacing: 3) {
                ForEach(Array(stride(from: 0, to: kinds.count, by: Self.columns)), id: \.self) { start in
                    HStack(spacing: 4) {
                        // A short last row keeps the columns of the rows above it.
                        ForEach(start..<start + Self.columns, id: \.self) { index in
                            if index < kinds.count {
                                share(kinds[index], shares[kinds[index]] ?? 0)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                            }
                        }
                    }
                }
            }
            VStack(spacing: 3) {
                ForEach(Array(month.payments.prefix(Self.largest).enumerated()), id: \.offset) { _, payment in
                    MoneyLine(payment: payment)
                }
            }
        }
    }

    /// The name in the panel's own grey beside a dot of the colour: the colour says which, the
    /// text stays text.
    private func share(_ kind: Money.Kind, _ percent: Int) -> some View {
        HStack(spacing: 3) {
            Circle().fill(kind.tint).frame(width: 6, height: 6)
            Text(kind.title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            Text("\(percent)%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of a month's largest lines. A credit is among them (asked 2026-10-07: "the + too"),
/// with its sign and in the panel's green; it was not spent on anything, so it has a plus where
/// a payment has the dot of its kind.
private struct MoneyLine: View {
    let payment: Money.Payment

    var body: some View {
        let credit = payment.amount > 0
        HStack(spacing: 6) {
            Text(payment.count > 1 ? "×\(payment.count)" : Money.day(payment.date))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 34, alignment: .trailing)
            Group {
                if let kind = payment.kind {
                    Circle().fill(kind.tint)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(SessionState.ready.tint)
                }
            }
            .frame(width: 6, height: 6)
            Text(payment.name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text((credit ? "+" : "−") + Money.euros(abs(payment.amount)))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(credit ? SessionState.ready.tint : .white.opacity(0.55))
                .fixedSize()
        }
    }
}
