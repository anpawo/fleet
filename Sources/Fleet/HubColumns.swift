import AppKit
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
        HubColumn(title: hub.showingSeen ? "SEEN" : "INBOX",
                  count: hub.mail.count, note: hub.failure) {
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
    /// Whether ⌘ is down. The column is a list while it is not, and a set of controls while it
    /// is — see `TodoCard`.
    let commandHeld: Bool
    /// A plain click anywhere puts the panel away, which is the panel's whole contract: it is a
    /// notification board, and getting out of it must never take aim.
    let onDismiss: () -> Void

    /// Many more than the mail column holds, because a todo is one line and a mail is two.
    /// Enough, in practice, that the list is never truncated at all — which is the point of a
    /// list whose whole job is to be the thing you have not done.
    private static let maxItems = 12

    /// Quick, but not instant — the ✕s arriving and leaving as ⌘ goes down and comes up.
    static let unroll: Animation = .easeOut(duration: 0.18)

    var body: some View {
        HubColumn(title: "TODO", count: hub.todos.count, note: hub.failure) {
            if hub.todos.isEmpty {
                HubEmptyLine(text: hub.loaded ? "Nothing to do" : "Loading\u{2026}")
            } else {
                ForEach(hub.todos.prefix(Self.maxItems)) { todo in
                    TodoCard(todo: todo,
                             commandHeld: commandHeld,
                             onFinish: { hub.markDone(todo) },
                             onDismiss: onDismiss)
                }
            }
        }
        // ⌘ going down or coming up is a state change from outside any of the handlers below,
        // so it needs its own animation or the whole column snaps.
        .animation(Self.unroll, value: commandHeld)
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

    /// The one mark on a card, and it is four points wide.
    ///
    /// The whole card used to be outlined in this colour when the mail was starred, and it was
    /// the loudest thing on the panel — a border reads at the edge of your vision, which is
    /// exactly where a mail has no business being when you opened this to look at your
    /// sessions. The star says the same thing to anyone who is already reading the column.
    ///
    /// Brass rather than gold: desaturated and dimmed off the amber the tiles use for a state,
    /// because this is not a state and should not answer to the same reflex.
    private static let starTint = Color(red: 0.78, green: 0.65, blue: 0.40)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if mail.starred {
                    Text("\u{2605}")
                        .font(.system(size: 9))
                        .foregroundStyle(Self.starTint)
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
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}

/// One todo, whole. However many lines its text takes, that is how tall the row is — no fold,
/// nothing hidden, nothing to open.
///
/// ⌘ is what separates reading from doing. Without it the row behaves like everything else on
/// the panel: a click puts it away, and there is nothing to aim at and nothing to hit by
/// accident. Hold ⌘ and every row swaps its age for a ✕, so clearing three things off the list
/// is three clicks without a row ever moving under the pointer.
struct TodoCard: View {
    let todo: Todo
    let commandHeld: Bool
    /// The ✕: finished, not deleted. The row leaves the column either way, and only one of the
    /// two can be taken back from the phone.
    let onFinish: () -> Void
    let onDismiss: () -> Void

    @State private var hoveringFinish = false

    private static let finishTint = Color(red: 1.00, green: 0.35, blue: 0.32)
    private static let fontSize: CGFloat = 11.5

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // A dot, not a ring. A ring is a checkbox — it invites a click that does nothing,
            // since finishing a todo here is the ✕ on the other side of the row.
            Circle()
                .fill(.white.opacity(0.32))
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 6)

            Text(todo.name)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            // The ✕ takes the age's place rather than sitting beside it, so nothing shifts
            // sideways the moment ⌘ goes down and the thing you were aiming at stays there.
            //
            // Stacked rather than swapped, and pinned to the age's height: the ✕ is a 16pt
            // target and the age is a 9pt line, so a plain swap made every row in the column
            // grow by a couple of points the instant ⌘ went down. The age keeps its place in
            // the layout with the lights off, the ✕ is drawn over it, and the pixels it spills
            // past the fixed height land in the row's own padding.
            ZStack(alignment: .trailing) {
                Text(shortAge(since: todo.createdAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .opacity(commandHeld ? 0 : 1)
                if commandHeld { finish }
            }
            .frame(height: 12, alignment: .trailing)
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }

    private var finish: some View {
        Button(action: onFinish) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Self.finishTint.opacity(hoveringFinish ? 1 : 0.75))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Self.finishTint.opacity(hoveringFinish ? 0.22 : 0.10)))
        }
        .buttonStyle(.plain)
        .onHover { hoveringFinish = $0 }
        .help("Mark done")
    }
}
