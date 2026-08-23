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
        // Named for what it holds, like TODO beside it — not for which pile of it you happen
        // to be looking at. Which pile that is goes in the note slot instead, in the dim type
        // the offline warning uses: a mail you have already dealt with must not be able to
        // pass for one that just arrived, but that is a footnote on the column, not its name.
        HubColumn(title: "MAIL",
                  count: hub.mail.count,
                  note: hub.failure ?? (hub.showingSeen ? "seen" : nil)) {
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

    /// The row under the pointer, which is the only one that opens. Held here rather than on
    /// the row, because a row is rebuilt from scratch every time the fleet refreshes — once a
    /// second while the panel is up — and state on a view that gets replaced does not survive.
    @State private var hovered: String?

    /// The row being dragged, ⌘ held: which one it is, where it started, and which slot it
    /// would drop into if you let go now.
    @State private var dragging: Dragging?
    /// How far the pointer has come since the press. Kept out of `Dragging` because the two
    /// move under different rules — the list rearranges itself with an animation, and the row
    /// under your hand must not.
    @State private var dragOffset: CGFloat = 0

    private struct Dragging: Equatable {
        let id: String
        let from: Int
        var to: Int
    }

    /// One row's height plus the gap under it. Every row is one line tall at rest — that is
    /// what the curtain in `TodoCard` is for — so the column is a regular grid, and where a
    /// dragged row has been taken is arithmetic rather than hit-testing.
    private static var pitch: CGFloat {
        FirstLine.lineHeight(size: TodoCard.fontSize) + TodoCard.verticalPadding * 2 + 8
    }

    /// Quick, but not instant. The point of the unroll is that you see which row grew and where
    /// the ones below it went; at zero duration the column simply teleports into a new shape and
    /// you have to find your place in it again.
    static let unroll: Animation = .easeOut(duration: 0.18)

    var body: some View {
        HubColumn(title: "TODO",
                  count: hub.todos.count,
                  note: hub.failure,
                  onAdd: { withAnimation(Self.unroll) { hub.compose() } }) {
            if hub.composing {
                NewTodoRow(hub: hub)
            }
            if hub.todos.isEmpty {
                if !hub.composing {
                    HubEmptyLine(text: hub.loaded ? "Nothing to do" : "Loading\u{2026}")
                }
            } else {
                ForEach(Array(hub.todos.prefix(Self.maxItems).enumerated()),
                        id: \.element.id) { index, todo in
                    TodoCard(todo: todo,
                             commandHeld: commandHeld,
                             // Hovering opens a row only while ⌘ is down. Without that guard the
                             // column would rearrange itself under a pointer merely crossing it
                             // on the way somewhere else. A row being dragged stays shut too:
                             // the grid the drag counts in only holds while every row is one
                             // line tall.
                             expanded: commandHeld && hovered == todo.id && dragging == nil,
                             lifted: dragging?.id == todo.id,
                             onFinish: { hub.markDone(todo) },
                             onHover: { inside in
                                 guard dragging == nil else { return }
                                 withAnimation(Self.unroll) {
                                     if inside { hovered = todo.id }
                                     else if hovered == todo.id { hovered = nil }
                                 }
                             },
                             onDismiss: onDismiss)
                        // Two offsets, on two views, with two different animations — and they
                        // have to stay two. The inner one is the pointer, and it is never
                        // animated; the outer one is a row stepping aside, and it always is.
                        // Written as one offset they share whichever animation the frame
                        // happens to carry, and on every frame where both change the row under
                        // your hand eases towards the pointer instead of being at it.
                        .offset(y: dragging?.id == todo.id ? dragOffset : 0)
                        .animation(nil, value: dragOffset)
                        .offset(y: stepAside(index))
                        .animation(Self.unroll, value: dragging)
                        // Over the rows it is passing, not under them.
                        .zIndex(dragging?.id == todo.id ? 1 : 0)
                        // `.gesture` rather than `.highPriorityGesture`: the ✕ is a subview and
                        // subview gestures win, so a click on it still finishes the todo while
                        // a drag from anywhere — the ✕ included — reorders.
                        .gesture(reorder(todo), including: commandHeld ? .all : .subviews)
                }
            }
        }
        // ⌘ going down or coming up is a state change from outside any of the handlers below,
        // so it needs its own animation or the whole column snaps.
        .animation(Self.unroll, value: commandHeld)
        // Letting ⌘ go mid-drag drops the row where it stands rather than leaving the column
        // holding a drag nothing can finish.
        .onChange(of: commandHeld) { if !commandHeld { drop() } }
    }

    /// How far a row that is *not* being dragged is drawn from its own slot: one row up if the
    /// dragged one has been taken past it downwards, one row down if upwards.
    ///
    /// The list itself is never reordered while a drag is in flight — the column draws it in
    /// exactly the order it is stored, and what moves is where each row is *drawn*. Reordering
    /// it live instead moves the dragged row's own slot out from under it, and the offset that
    /// has to cancel that out can only do so on the very frame the layout changes. It never
    /// quite does, so the row lags, overshoots and swims back — which is what this used to do.
    private func stepAside(_ index: Int) -> CGFloat {
        guard let dragging, dragging.from != dragging.to else { return 0 }
        if dragging.from < dragging.to {
            return (dragging.from + 1 ... dragging.to).contains(index) ? -Self.pitch : 0
        }
        return (dragging.to ..< dragging.from).contains(index) ? Self.pitch : 0
    }

    /// ⌘ and a drag: the todo follows the pointer, and the slot it is over is worked out from
    /// how many rows it has travelled.
    private func reorder(_ todo: Todo) -> some Gesture {
        // Global, not local. The row is offset by this very gesture, so measuring in its own
        // coordinate space feeds the offset back into the next reading: the translation is
        // taken against a frame that has already moved by it, and the row jitters instead of
        // tracking the pointer.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let visible = hub.todos.prefix(Self.maxItems)
                guard let from = dragging?.from
                        ?? visible.firstIndex(where: { $0.id == todo.id }) else { return }
                dragOffset = value.translation.height
                let travelled = Int((value.translation.height / Self.pitch).rounded())
                let to = min(max(from + travelled, 0), visible.count - 1)
                guard dragging?.to != to else { return }
                // No `withAnimation`: the rows stepping aside are animated by the modifier that
                // watches `dragging`, and an explicit transaction here would reach the dragged
                // row's own offset as well.
                dragging = Dragging(id: todo.id, from: from, to: to)
            }
            .onEnded { _ in drop() }
    }

    /// Let go. The write goes out here and nowhere else — a drag crossing six rows is one
    /// document changed, not six.
    private func drop() {
        guard let dragging else { return }
        hub.move(dragging.id, to: dragging.to)
        self.dragging = nil
        dragOffset = 0
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
    /// The + on the heading, for a column you can write into. Nil on one that only reports.
    var onAdd: (() -> Void)?
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
                if let onAdd {
                    AddButton(action: onAdd)
                        // Pinned to the heading's own line: the button is 16pt tall and the
                        // words beside it are 11pt, so left to itself it would push this column
                        // rule a couple of points below the one on MAIL. What it spills lands
                        // in the gap above the rule.
                        .frame(height: 13)
                }
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

            // Matches the room the fleet leaves under its own rule, so the first mail, the
            // first tile and the first todo all start on the same line.
            VStack(spacing: 8) { content }
                .padding(.top, 8)
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

/// One todo. One line at rest, its whole text on ⌘-click, and a ✕ that finishes it.
///
/// ⌘ is what separates reading from doing here. Without it the row behaves like everything else
/// on the panel — a click puts the panel away — and there is nothing to aim at and nothing to
/// hit by accident. Hold ⌘ and every row grows a ✕ where its age was, so clearing three things
/// off the list is three clicks without the row ever moving under the pointer.
struct TodoCard: View {
    let todo: Todo
    let commandHeld: Bool
    let expanded: Bool
    /// Whether this is the row being dragged. Off the page a little, and lit — a card that has
    /// been picked up has to be told apart from the ones sliding around underneath it.
    var lifted = false
    /// The ✕: finished, not deleted. The row leaves the column either way, and only one of the
    /// two can be taken back from the phone.
    let onFinish: () -> Void
    let onHover: (Bool) -> Void
    let onDismiss: () -> Void

    @State private var hoveringFinish = false
    /// The room the text has to wrap in. Seeded with roughly the right number, so the first
    /// frame is not laid out against a width of zero.
    @State private var textWidth: CGFloat = 190

    private static let finishTint = Color(red: 1.00, green: 0.35, blue: 0.32)
    static let fontSize: CGFloat = 11.5
    /// Above and below the text, on each side. Part of what makes a row's height, which the
    /// column needs to know to work out where a dragged row has been taken.
    static let verticalPadding: CGFloat = 7

    private var metrics: FirstLine.Metrics {
        FirstLine.metrics(todo.name, width: textWidth, size: Self.fontSize)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // A dot, not a ring. A ring is a checkbox — it invites a click that does nothing,
            // since finishing a todo here is the ✕ on the other side of the row.
            Circle()
                .fill(.white.opacity(0.32))
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 6)

            // A curtain, not a re-layout. The whole text is laid out once, at its full height,
            // and never touched again; what moves is the edge it is clipped to. Nothing fades
            // in, nothing re-wraps, no word is ever in two places on the way down — the lines
            // below the fold have been sitting there the whole time, unlit.
            //
            // Which is why the height has to be a number on both sides. `nil` and "one line"
            // are not two values with anything in between, so there would be nothing to
            // animate; measuring the text gives the two ends of a real interpolation.
            Text(todo.name)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // Takes the whole width rather than sitting next to a spacer, so what the
                // readers below measure is the room the text actually has to wrap in.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: TextWidth.self, value: proxy.size.width)
                })
                // Sits where the first line's last word ends, so it reads as part of that line
                // rather than as something parked at the right margin.
                .overlay(alignment: .topLeading) {
                    if !expanded, metrics.truncated {
                        Text("\u{2026}")
                            .font(.system(size: Self.fontSize))
                            .foregroundStyle(.white.opacity(0.85))
                            .offset(x: metrics.firstLineWidth + 1)
                    }
                }
                .frame(height: expanded ? metrics.fullHeight : metrics.lineHeight,
                       alignment: .top)
                .clipped()
                // A zero is what an offscreen pass reports before it has laid anything out, and
                // it would throw away a perfectly good seed and collapse every todo to one line.
                .onPreferenceChange(TextWidth.self) { if $0 > 24 { textWidth = $0 } }

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
        .padding(.vertical, Self.verticalPadding)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // Not brightened while ⌘ is down. It was, and every row in the column changing
                // shade at once read as the whole list reacting — a flicker you notice and then
                // have to interpret. The ✕ appearing is the entire announcement needed.
                //
                // One row *being dragged* is the exception: that one is answering your hand,
                // and it is the only thing on the panel that is.
                .strokeBorder(.white.opacity(lifted ? 0.34 : 0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(lifted ? 0.55 : 0), radius: lifted ? 12 : 0, y: 4)
        .contentShape(Rectangle())
        // Every click puts the panel away, ⌘ or no ⌘. Opening a row is the pointer's job and
        // nothing else's, so there is nothing here a click could mean instead.
        .onTapGesture { onDismiss() }
        .onHover { onHover($0) }
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


/// The + on a column heading. Sized and shaded like the ✕ on a todo, because it is the same
/// kind of thing: a small target that appears on a heading and does one thing to the list.
struct AddButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.5))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add a todo")
    }
}

/// The row the + opens: a todo being written, at the top of the column.
///
/// Built to be the same row as the ones under it — same dot, same card, same type — so what
/// you are typing is already sitting where it will end up. Return files it and leaves the row
/// open for the next one; Esc takes it back.
struct NewTodoRow: View {
    @ObservedObject var hub: HubStore

    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(.white.opacity(0.32))
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 6)

            // Vertical axis, like the prompt: a todo is occasionally a paragraph, and it should
            // wrap rather than scroll off the side. Return never reaches the field editor here —
            // the panel window claims it — so wrapping costs nothing.
            TextField("New todo", text: $hub.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.9))
                .tint(.white.opacity(0.8))
                .lineLimit(1 ... 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($editing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // Brighter than a todo's border: this row is being typed into, and the only
                // other lit thing on the panel is the prompt field.
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
        // A click in the padding around the field would otherwise be an unclaimed tap, and an
        // unclaimed tap on this panel puts it away — mid-sentence.
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .onAppear { editing = true }
        // Return goes to whichever field has the caret, and only the field knows which that is.
        .onChange(of: editing) { hub.composerFocused = editing }
    }
}

private struct TextWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}


/// How a piece of text lays itself out in a column this wide: how many lines it takes, how tall
/// each one is, and where the first one ends.
///
/// Computed rather than measured, and that is deliberate. The row's two heights have to be
/// numbers on both sides of the animation or there is nothing to interpolate between, and
/// asking SwiftUI to report the height it arrived at means waiting a frame for the answer to
/// come back through a preference — which is a frame in which the row has the wrong height, and
/// which never comes at all in an offscreen render. `CTTypesetterSuggestLineBreak` gives the
/// same answer the layout will give, before the layout happens.
///
/// The line height is the font's own — ascender to descender plus leading — which is what
/// SwiftUI uses for a plain `Text`. Checked against the rendered article: a one-line row comes
/// out 28pt tall, which is this 14 plus the row's 7pt of padding top and bottom.
enum FirstLine {
    struct Metrics {
        var lineHeight: CGFloat
        var lineCount: Int
        /// How wide the first line's text is, from the leading edge — where the ellipsis goes.
        var firstLineWidth: CGFloat

        var fullHeight: CGFloat { lineHeight * CGFloat(lineCount) }
        /// Whether anything is below the fold.
        var truncated: Bool { lineCount > 1 }
    }

    /// A line of this font, ascender to descender plus leading — what SwiftUI gives a plain
    /// `Text`, and what a row of the todo column is tall.
    static func lineHeight(size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return ceil(font.ascender - font.descender + font.leading)
    }

    static func metrics(_ text: String, width: CGFloat, size: CGFloat) -> Metrics {
        let font = NSFont.systemFont(ofSize: size)
        let lineHeight = lineHeight(size: size)
        let single = Metrics(lineHeight: lineHeight, lineCount: 1, firstLineWidth: 0)
        guard width > 24, !text.isEmpty else { return single }

        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = text as NSString

        var start = 0
        var lines = 0
        var firstWidth: CGFloat = 0
        // The bound is a runaway guard, not a policy: a todo is occasionally a pasted receipt,
        // and the column sits in a scroll view that can take it.
        while start < attributed.length, lines < 60 {
            let fits = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard fits > 0 else { break }
            if lines == 0 {
                let head = ns.substring(with: NSRange(location: start, length: Int(fits)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                firstWidth = NSAttributedString(string: head,
                                                attributes: [.font: font]).size().width
            }
            start += Int(fits)
            lines += 1
        }
        return Metrics(lineHeight: lineHeight, lineCount: max(lines, 1), firstLineWidth: firstWidth)
    }
}
