import SwiftUI

/// The panel's left column: the mail the triage engine scored and nobody has dealt with yet,
/// most important first.
///
/// Read-only, for now. Everything here is one PATCH away from being actionable — the same
/// three-line REST call the phone's widget makes to move a todo along — and the plan is that
/// the panel grows into a way of working this list rather than only looking at it. Until then
/// a click anywhere in these columns dismisses the panel, like any other empty space.
struct MailColumn: View {
    @ObservedObject var hub: HubStore

    /// Six cards is what fits beside three rows of tiles. A seventh would make the column
    /// taller than the fleet, and the column is not the point of the panel.
    private static let maxItems = 6

    var body: some View {
        HubColumn(title: "INBOX", count: hub.mail.count, note: hub.failure) {
            if hub.mail.isEmpty {
                HubEmptyLine(text: hub.loaded ? "Nothing waiting" : "Loading\u{2026}")
            } else {
                ForEach(hub.mail.prefix(Self.maxItems)) { MailCard(mail: $0) }
            }
        }
    }
}

/// The panel's right column: the todo list, oldest first — the one that has been sitting there
/// longest is the one worth being reminded of.
struct TodoColumn: View {
    @ObservedObject var hub: HubStore

    /// Many more than the mail column holds, because a todo is one line and a mail is four.
    /// Enough, in practice, that the list is never truncated at all — which is the point of a
    /// list whose whole job is to be the thing you have not done.
    private static let maxItems = 12

    var body: some View {
        HubColumn(title: "TODO", count: hub.todos.count, note: hub.failure) {
            if hub.todos.isEmpty {
                HubEmptyLine(text: hub.loaded ? "Nothing to do" : "Loading\u{2026}")
            } else {
                ForEach(hub.todos.prefix(Self.maxItems)) { TodoCard(todo: $0) }
            }
        }
    }
}

/// What both columns have in common: a label, how many there are in total, and the rows.
///
/// The count is of everything, not of what is drawn — a column showing six of eleven should
/// say eleven, or it quietly claims the list is shorter than it is.
struct HubColumn<Content: View>: View {
    let title: String
    let count: Int
    /// A word about why the list may not be current — "offline", usually. Nil when it is.
    let note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3.2)
                    .foregroundStyle(.white.opacity(0.45))
                if let note {
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
            .padding(.horizontal, 2)

            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)

            VStack(spacing: 8) { content }
        }
    }
}

/// A column with nothing in it — either because there is nothing, or because the first fetch
/// has not come back yet. Which of the two it is matters, so the two say different things.
struct HubEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.25))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, 2)
    }
}

/// One scored mail. The engine's headline first, because it is the only line written to be read
/// at this size; the sender is what tells you whether to believe it.
struct MailCard: View {
    let mail: Mail

    /// The score, as the one colour on the card. Deliberately not one of the three state tints
    /// — those mean something about a session, and a mail that borrowed the blue would read as
    /// a fourth thing needing an answer. Amber is the "in flight" colour the sub-agent line
    /// already uses, and a 3 is exactly that: something of yours in flight elsewhere.
    private var accent: Color {
        switch mail.importance {
        case 3...: return SessionTile.subagentTint
        case 2: return .white.opacity(0.30)
        default: return .white.opacity(0.13)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mail.gist)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(shortAge(since: mail.receivedAt))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Text(mail.sender)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)

            Text(mail.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        // Inside the clip, so the bar follows the rounded corners instead of squaring them off.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}

/// One todo, one line. The age on the right is the whole editorial: a todo from this morning is
/// a plan, one from three weeks ago is a question.
struct TodoCard: View {
    let todo: Todo

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .strokeBorder(.white.opacity(0.28), lineWidth: 1.2)
                .frame(width: 9, height: 9)

            Text(todo.title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(shortAge(since: todo.createdAt))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}
