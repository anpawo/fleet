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

    /// What fits beside three rows of tiles now that a card is two lines rather than four.
    private static let maxItems = 10

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

/// One mail: who sent it, and what it is about. Nothing else.
///
/// The engine writes a summary too, and it used to be on the card. Two lines of grey prose per
/// mail is a paragraph down the side of the panel — you end up reading it, and the point of
/// this column is to be *counted*, not read. The name and the subject answer the only question
/// a glance is asking, which is whether any of this needs you before the sessions do.
struct MailCard: View {
    let mail: Mail

    /// Starred by you, or scored a 3 by the engine. The whole card is outlined in amber when
    /// it is — and nothing marks the rest.
    ///
    /// A three-step scale down the left edge was tried and dropped: a grey bar and a fainter
    /// grey bar are two shades nobody reads as a ranking, so all they did was add a second
    /// vertical line to every card. Important or not is the only distinction this column is
    /// narrow enough to make.
    private var important: Bool { mail.starred || mail.importance >= 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if mail.starred {
                    Text("\u{2605}")
                        .font(.system(size: 9))
                        .foregroundStyle(SessionTile.subagentTint)
                }
                // The engine's headline, not the Gmail subject — there is no subject stored on
                // the document. See the note in `Mail`.
                Text(mail.gist)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(shortAge(since: mail.receivedAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
            }

            Text(mail.sender)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(important ? SessionTile.subagentTint : .white.opacity(0.07),
                              lineWidth: important ? 1.5 : 1)
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
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(shortAge(since: todo.createdAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}
