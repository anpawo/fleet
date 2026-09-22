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
    /// ⌘ est enfoncée : la carte sous le pointeur se déplie et montre ses quatre boutons. Le
    /// même marché que la colonne TODO — sans ⌘ il n'y a rien à viser et rien à rater.
    var commandHeld = false
    /// Off for an offscreen render, like the two columns below it: `ImageRenderer` draws
    /// nothing inside a `ScrollView`.
    var scrolling = true

    /// La carte sous le pointeur. Sur la colonne et pas sur la carte : une carte est reconstruite
    /// à chaque tick.
    @State private var hovered: String?

    /// What fits beside three rows of tiles now that a card is two lines rather than four.
    private static let maxItems = 10

    var body: some View {
        // Named for what it holds, like TODO beside it — not for which pile of it you happen
        // to be looking at. Which pile that is goes in the note slot instead, in the dim type
        // the offline warning uses: a mail you have already dealt with must not be able to
        // pass for one that just arrived, but that is a footnote on the column, not its name.
        HubColumn(title: "MAIL",
                  count: hub.mail.count,
                  showsZero: true,
                  // What is wrong with Firestore is over the fleet now — see `AlertsBlock`.
                  // What is left here is which pile you are looking at.
                  note: hub.showingSeen ? "seen" : nil,
                  tint: BlockTint.mail,
                  fill: BlockTint.mail.darkened(0.36),
                  minRows: 3,
                  fills: true) {
            // The block is a third of the column now, whatever it holds, so what does not fit
            // scrolls rather than running down over the school underneath it.
            if scrolling {
                ScrollView(.vertical) {
                    VStack(spacing: 8) { rows }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 8) { rows }
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if !hub.loaded {
            HubEmptyLine(text: "Loading\u{2026}")
        }
        ForEach(hub.mail.prefix(Self.maxItems)) { mail in
            MailCard(hub: hub, mail: mail,
                     expanded: commandHeld && hovered == mail.id,
                     onHover: { inside in
                         if inside { hovered = mail.id } else if hovered == mail.id { hovered = nil }
                     })
        }
    }
}

/// What this machine does on its own: one line per LaunchAgent of his, and what it is for
/// under ⌘.
///
/// Over the todos rather than beside them, and half the column each. These are the jobs that
/// run whether or not anyone is looking — the reason a deadline appears in the block below
/// without anybody typing it — and the only time you think about one is the day it stops.
///
/// Blue, off the RAM's own blue: the two blocks that report on the machine rather than on
/// what you owe anyone.
struct CronColumn: View {
    /// Whether ⌘ is down. A wall of names at rest; the one under the pointer says what it is
    /// for and how often it runs while it is held.
    let commandHeld: Bool
    /// Off for an offscreen render, like every other scrolling block.
    var scrolling = true

    /// The card under the pointer — the only one ⌘ unfolds. On the column rather than the
    /// card, like the two grids above it: a card is rebuilt every tick.
    @State private var hovered: String?

    /// Read once a tick, like everything else on the panel: `launchctl list` is a pipe and a
    /// folder listing, and the panel is redrawn at a second's rhythm.
    private var jobs: [Launchd.Job] { Launchd.jobs() }

    /// The RAM block's blue, which is the one the panel already uses for "the machine is
    /// speaking". Not `BlockTint.memory` — that is the grey the heading chip wears.
    static let tint = SessionState.awaitingAnswer.tint

    private static let pair = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        // The healthy ones first. Fourteen green borders are wallpaper; what the block is for
        // is the two that are not, and they have to be in the same place every time.
        let all = jobs.sorted { ($0.ok ? 0 : 1, $0.name) < ($1.ok ? 0 : 1, $1.name) }
        HubColumn(title: "CRON",
                  count: all.count,
                  showsZero: true,
                  tint: Self.tint,
                  fill: Self.tint.darkened(0.48),
                  minRows: 3,
                  fills: true) {
            if scrolling {
                ScrollView(.vertical) {
                    VStack(spacing: 6) { rows(all) }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 6) { rows(all) }
            }
        }
        .animation(TodoColumn.unroll, value: commandHeld)
        .animation(TodoColumn.unroll, value: hovered)
    }

    @ViewBuilder private func rows(_ all: [Launchd.Job]) -> some View {
        if all.isEmpty {
            HubEmptyLine(text: "No agent installed")
        }
        LazyVGrid(columns: Self.pair, spacing: 6) {
            ForEach(all) { job in
                CronCard(job: job, expanded: commandHeld && hovered == job.id)
                    .onHover { inside in
                        if inside { hovered = job.id } else if hovered == job.id { hovered = nil }
                    }
            }
        }
    }
}

/// One agent, half the block wide. A name and a border: green for one launchd has loaded and
/// whose last run was clean, red for one that is unloaded or came back on an error. Under ⌘,
/// and only the one being pointed at, what it does and how often it does it.
struct CronCard: View {
    let job: Launchd.Job
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                Text(job.note)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Text(job.schedule)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(border.opacity(expanded ? 0.95 : 0.5), lineWidth: 1)
        )
    }

    private var border: Color {
        job.ok ? SessionState.ready.tint : SessionState.running.tint
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
    /// Off for an offscreen render: `ImageRenderer` draws nothing inside a `ScrollView`, and a
    /// screenshot of the panel showed an empty column under a count of 21.
    var scrolling = true

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
                  note: nil,
                  onAdd: { withAnimation(Self.unroll) { hub.compose() } },
                  tint: BlockTint.todo,
                  fill: BlockTint.todo.darkened(0.44),
                  fills: true) {
            // The list scrolls, the heading does not, and the rest of the panel does not
            // move at all — the fleet either side has its own scroll for the same reason.
            // The horizontal padding is the room a lifted card's shadow needs, taken inside
            // and given back outside, so the clip lands out of its reach.
            if scrolling {
                ScrollView(.vertical) {
                    VStack(spacing: 8) { rows }
                        .padding(.horizontal, Self.glowRoom)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .padding(.horizontal, -Self.glowRoom)
                // The height the column was given, whatever the list holds — it ends on the
                // same line as the EPITECH block on the other side of the panel, and the rows
                // past that scroll.
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 8) { rows }
            }
        }
        // ⌘ going down or coming up is a state change from outside any of the handlers below,
        // so it needs its own animation or the whole column snaps.
        .animation(Self.unroll, value: commandHeld)
        // Letting ⌘ go mid-drag drops the row where it stands rather than leaving the column
        // holding a drag nothing can finish.
        .onChange(of: commandHeld) { if !commandHeld { drop() } }
    }

    /// How far a lifted card's shadow reaches past the column, and the room the scroll view
    /// has to give it back.
    private static let glowRoom: CGFloat = 16

    @ViewBuilder private var rows: some View {
            if hub.composing {
                NewTodoRow(hub: hub)
            }
            if hub.todos.isEmpty {
                if !hub.composing {
                    HubEmptyLine(text: hub.loaded ? "Nothing to do" : "Loading\u{2026}")
                }
            } else {
                let visible = hub.todos
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, todo in
                    // A folder heading over the first row of each run. On the heading and not
                    // in the row, because the modifiers below are what step a row aside during
                    // a drag, and a heading must not go with it.
                    if index == 0 || visible[index - 1].bucket != todo.bucket {
                        Text(todo.bucket.title)
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                            .padding(.top, index == 0 ? 0 : 6)
                    }
                    TodoCard(hub: hub,
                             todo: todo,
                             commandHeld: commandHeld,
                             // Hovering opens a row only while ⌘ is down. Without that guard the
                             // column would rearrange itself under a pointer merely crossing it
                             // on the way somewhere else. A row being dragged stays shut too:
                             // the grid the drag counts in only holds while every row is one
                             // line tall.
                             expanded: commandHeld && hovered == todo.id && dragging == nil,
                             lifted: dragging?.id == todo.id,
                             spotlit: hub.spotlightID == todo.id,
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
                let visible = hub.todos
                guard let from = dragging?.from
                        ?? visible.firstIndex(where: { $0.id == todo.id }) else { return }
                dragOffset = value.translation.height
                let travelled = Int((value.translation.height / Self.pitch).rounded())
                // Within its own run only: the rows under one heading, dated or not. The grid
                // arithmetic holds only while no heading lies between the row and its slot —
                // and a deadline dragged past another would be sorted straight back anyway.
                let same = { (other: Todo) in
                    other.bucket == todo.bucket && (other.due == nil) == (todo.due == nil)
                }
                let low = visible.firstIndex(where: same) ?? from
                let high = visible.lastIndex(where: same) ?? from
                let to = min(max(from + travelled, low), high)
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
    /// Whether a count of zero is drawn. Off by default — a column with rows in it says how
    /// many and a column with none says nothing — and on for MAIL, where the empty line that
    /// used to say so is gone and the nought is all that is left to say it.
    var showsZero = false
    /// A word about why the list may not be current — "offline", usually. Nil when it is.
    var note: String?
    /// The + on the heading, for a column you can write into. Nil on one that only reports.
    var onAdd: (() -> Void)?
    /// The colour of the chip behind the name — see `BlockTint`.
    var tint: Color = Color(white: 0.24)
    /// The wash inside the frame, when the tint's own is too much of it. The two blue blocks
    /// are the only ones deep enough in colour for the wash to read as a coloured card rather
    /// than as black paper with a coloured edge.
    var fill: Color?
    /// What goes top right in place of the count, when a number of rows is not the figure worth
    /// having there.
    var badge: String?
    /// Whether the note is bad news rather than a footnote. Red, because a session that has
    /// quietly expired otherwise looks exactly like a calm week.
    var noteIsAlarm = false
    /// A blinking red light beside the name. On when the block cannot see what it is meant to
    /// report — the one thing on this panel that asks to be noticed from across the room.
    var alarm = false
    /// How round the frame's corners are. A one-line block wears the same 12pt as a column of
    /// cards as a capsule; the short ones ask for less.
    var radius: CGFloat = 12
    /// How many rows of room the column keeps whether or not it has them to show. An empty
    /// MAIL that collapses to a line, and grows back the moment something lands, moves every
    /// block under it — the left column would rearrange itself all morning.
    var minRows = 0
    /// Whether the rows take whatever height the column has been given rather than only what
    /// they need. A block that scrolls has to be told how tall it is, and the one at the foot
    /// of the left column is as tall as what is left of the screen.
    var fills = false
    @ViewBuilder let content: Content

    /// The figure top right: whatever `badge` says, or the count of rows. Nil when neither.
    private var cornerLabel: String? {
        if let badge { return badge }
        return count > 0 || showsZero ? "\(count)" : nil
    }

    @ViewBuilder private var corner: some View {
        if let cornerLabel {
            Text(cornerLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .titleGround()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3.2)
                    .foregroundStyle(alarm ? SessionState.running.tint : .white.opacity(0.92))
                    .blinking(alarm)
                    .titleGround()
                if let note {
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(noteIsAlarm ? SessionState.running.tint
                                                    : .white.opacity(0.3))
                        .lineLimit(1)
                        .titleGround()
                        // The chip behind the name bleeds 7pt past the text on either side,
                        // which ate the gap the HStack was leaving here.
                        .padding(.leading, 15)
                }
                Spacer(minLength: 4)
                // The + and the figure are one control on a column you can write into: two
                // chips a few points apart, one of them clickable and the other not, is a
                // target you have to aim at. Together they are the size of a button.
                if let onAdd {
                    AddButton(action: onAdd, count: cornerLabel)
                } else {
                    corner
                }
            }
            .padding(.horizontal, 2)

            // Matches the room the fleet leaves under its own heading, so the first mail, the
            // first tile and the first todo all start on the same line.
            VStack(spacing: 8) { content }
                .frame(minHeight: MailCard.room(forRows: minRows),
                       maxHeight: fills ? .infinity : nil, alignment: .top)
                .padding(.top, 9)
        }
        .blockFrame(tint, fill: fill, radius: radius)
    }
}

/// The one thing on the panel that blinks: a block's own name, when the block cannot see what
/// it is meant to report.
///
/// The name and not a light beside it — a lamp in a corner is furniture, and what is wrong here
/// is the whole block. Half a second is slow enough to read as a pulse rather than a flicker.
/// The chip behind the name does not blink with it: a ground that comes and goes reads as the
/// heading itself being redrawn.
struct Blinking: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.25 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

extension View {
    func blinking(_ active: Bool) -> some View { modifier(Blinking(active: active)) }
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
    @ObservedObject var hub: HubStore
    let mail: Mail
    /// ⌘ est enfoncée et le pointeur est ici.
    var expanded = false
    var onHover: (Bool) -> Void = { _ in }

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

    /// How much room a given number of these takes, gaps included — what MAIL and EPITECH
    /// keep clear whether or not they have that much to put in it. Neither line wraps, so
    /// this is the two line heights and the padding round them.
    static func room(forRows rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let card = FirstLine.lineHeight(size: 12) + 3 + FirstLine.lineHeight(size: 9.5) + 16
        return CGFloat(rows) * card + CGFloat(rows - 1) * 8
    }

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

            if expanded {
                // Ce que le moteur a compris, puis ce qu'on peut en faire. Le résumé d'abord :
                // les quatre boutons ne veulent rien dire tant qu'on n'a pas lu le mail.
                if !mail.summary.isEmpty {
                    Text(mail.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                // Deux par ligne : quatre boutons sur une ligne dans un cinquième de panneau
                // sont quatre cibles de vingt points.
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        MailActionButton(.seen) { hub.act(.seen, on: mail) }
                        MailActionButton(.done) { hub.act(.done, on: mail) }
                    }
                    HStack(spacing: 4) {
                        MailActionButton(.trash) { hub.act(.trash, on: mail) }
                        MailActionButton(.later) { hub.act(.later, on: mail) }
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(expanded ? 0.2 : 0.07), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { onHover($0) }
    }
}

/// Un des quatre boutons du bas d'une carte dépliée.
///
/// Les couleurs sont celles du téléphone, au point près — my-hub montre le même verdict en
/// glissant la carte, et un geste vert là-bas ne doit pas être un bouton gris ici.
struct MailActionButton: View {
    let action: HubStore.MailAction
    let run: () -> Void
    @State private var hovering = false

    init(_ action: HubStore.MailAction, run: @escaping () -> Void) {
        self.action = action
        self.run = run
    }

    /// `MailUi.kt` : HintAnswer, HintDone, HintBanned, HintLater.
    private var tint: Color {
        switch action {
        case .seen: return Color(red: 0.039, green: 0.518, blue: 1.0)    // #0A84FF
        case .done: return Color(red: 0.188, green: 0.820, blue: 0.345)  // #30D158
        case .trash: return Color(red: 1.0, green: 0.271, blue: 0.227)   // #FF453A
        case .later: return Color(red: 0.749, green: 0.353, blue: 0.949) // #BF5AF2
        }
    }

    var body: some View {
        Button(action: run) {
            Text(action.label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(hovering ? 0.22 : 0.10)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One todo. One line at rest, its whole text on ⌘-click, and a ✕ that finishes it.
///
/// ⌘ is what separates reading from doing here. Without it the row behaves like everything else
/// on the panel — a click puts the panel away — and there is nothing to aim at and nothing to
/// hit by accident. Hold ⌘ and every row grows a ✕ where its age was, so clearing three things
/// off the list is three clicks without the row ever moving under the pointer.
struct TodoCard: View {
    @ObservedObject var hub: HubStore
    let todo: Todo
    let commandHeld: Bool
    let expanded: Bool
    /// Whether this is the row being dragged. Off the page a little, and lit — a card that has
    /// been picked up has to be told apart from the ones sliding around underneath it.
    var lifted = false
    /// This opening's reminder — see `HubStore.spotlightID`. White, not a tint: every colour on
    /// the panel already means a state or a deadline.
    var spotlit = false
    /// The ✕: finished, not deleted. The row leaves the column either way, and only one of the
    /// two can be taken back from the phone.
    let onFinish: () -> Void
    let onHover: (Bool) -> Void
    let onDismiss: () -> Void

    @State private var hoveringFinish = false
    @State private var hoveringEdit = false
    @FocusState private var typing: Bool

    private var editing: Bool { hub.editingID == todo.id }
    /// The room the text has to wrap in. Seeded with roughly the right number, so the first
    /// frame is not laid out against a width of zero.
    @State private var textWidth: CGFloat = 190

    private static let finishTint = Color(red: 1.00, green: 0.35, blue: 0.32)
    private static let editTint = Color(red: 0.27, green: 0.62, blue: 1.00)
    static let fontSize: CGFloat = 11.5
    /// Above and below the text, on each side. Part of what makes a row's height, which the
    /// column needs to know to work out where a dragged row has been taken.
    static let verticalPadding: CGFloat = 7

    /// How soon, in the panel's own four colours: red for today or already past, amber for
    /// this week, blue for next week, green beyond. Grey for a line with no day in it — most
    /// of the list, and the point of the colour is that the dated ones stand out of it.
    private var dueTint: Color {
        guard let due = todo.due else { return .white.opacity(0.32) }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case ..<1: return SessionState.running.tint
        case ..<8: return SessionState.apiError.tint
        case ..<15: return SessionState.awaitingAnswer.tint
        default: return SessionState.ready.tint
        }
    }

    private var metrics: FirstLine.Metrics {
        FirstLine.metrics(todo.name, width: textWidth, size: Self.fontSize)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // A dot, not a ring. A ring is a checkbox — it invites a click that does nothing,
            // since finishing a todo here is the ✕ on the other side of the row.
            Circle()
                .fill(dueTint)
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
            if editing {
                // The same type at the same place, so the row does not jump when it opens.
                // Vertical axis like the new-todo row: a todo is occasionally a paragraph and
                // it should wrap rather than scroll off the side.
                TextField("", text: $hub.editDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: Self.fontSize))
                    .foregroundStyle(.white.opacity(0.95))
                    .tint(.white.opacity(0.8))
                    .lineLimit(1 ... 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($typing)
                    .onAppear { typing = true }
            } else {
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
            }

            // The ✕ takes the age's place rather than sitting beside it, so nothing shifts
            // sideways the moment ⌘ goes down and the thing you were aiming at stays there.
            //
            // Stacked rather than swapped, and pinned to the age's height: the ✕ is a 16pt
            // target and the age is a 9pt line, so a plain swap made every row in the column
            // grow by a couple of points the instant ⌘ went down. The age keeps its place in
            // the layout with the lights off, the ✕ is drawn over it, and the pixels it spills
            // past the fixed height land in the row's own padding.
            // The pencil sits to the left of the ✕ and outside the stack that holds the age's
            // place, because it has no place to take: nothing was there before ⌘ went down.
            // Always in the layout, lit only under ⌘. It used to appear with the key, and
            // appearing took 25pt off the text beside it — so every truncated row re-wrapped
            // and its ellipsis jumped the moment you reached for the pencil.
            edit
                .opacity(commandHeld && !editing ? 1 : 0)
                .allowsHitTesting(commandHeld && !editing)
                .frame(height: 12, alignment: .trailing)
                .padding(.top, 1)
            ZStack(alignment: .trailing) {
                Text(shortAge(since: todo.createdAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .opacity(commandHeld ? 0 : 1)
                if commandHeld { finish }
            }
            // A fixed width, not whatever the stack measures: "2d" is eleven points and the ✕
            // is sixteen, so on a young todo ⌘ took five points off the text, and the row
            // re-wrapped and moved its ellipsis. The widest age, "11mo", measures 22.3.
            .frame(width: 23, height: 12, alignment: .trailing)
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, Self.verticalPadding)
        .background(spotlit ? Color(red: 0.15, green: 0.15, blue: 0.18)
                            : Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // Not brightened while ⌘ is down. It was, and every row in the column changing
                // shade at once read as the whole list reacting — a flicker you notice and then
                // have to interpret. The ✕ appearing is the entire announcement needed.
                //
                // One row *being dragged* is the exception: that one is answering your hand,
                // and it is the only thing on the panel that is.
                .strokeBorder(.white.opacity(lifted ? 0.34 : spotlit ? 0.4 : 0.07), lineWidth: 1)
        )
        // Cast only while lifted, and from a shape of its own. As a modifier on the row it was
        // there at rest too, invisible — and a shadow taken from a group of layers is an
        // offscreen pass per row, per frame, for as long as the column scrolls.
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
            }
        }
        .contentShape(Rectangle())
        // Every click puts the panel away, ⌘ or no ⌘. Opening a row is the pointer's job and
        // nothing else's, so there is nothing here a click could mean instead.
        .onTapGesture { if editing { typing = true } else { onDismiss() } }
        .onHover { onHover($0) }
    }

    /// Sized and shaded like the ✕ beside it, in the panel's own blue rather than its red:
    /// the two do opposite things to a row, and one of them is not undoable from here.
    private var edit: some View {
        Button { hub.edit(todo) } label: {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Self.editTint.opacity(hoveringEdit ? 1 : 0.75))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Self.editTint.opacity(hoveringEdit ? 0.22 : 0.10)))
        }
        .buttonStyle(.plain)
        .onHover { hoveringEdit = $0 }
        .help("Edit")
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
    /// The column's own figure, on the same chip as the +. Two grounds a few points apart,
    /// one of them clickable and the other not, is a target you have to aim at; together they
    /// are one control the size of a button.
    var count: String?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
                if let count {
                    Text(count)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(hovering ? 0.75 : 0.45))
                }
            }
            .titleGround()
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(hovering ? 0.10 : 0))
                .padding(.horizontal, -7)
                .padding(.vertical, -3))
            .contentShape(Rectangle())
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
        /// The same for every line, first included; the Reels card folds lower than the first.
        var lineWidths: [CGFloat] = []

        var fullHeight: CGFloat { lineHeight * CGFloat(lineCount) }
        /// Whether anything is below the fold.
        var truncated: Bool { lineCount > 1 }

        /// Where a fold `lines` deep ends: the width of the last line above it.
        func lastShownLineWidth(_ lines: Int) -> CGFloat {
            lineWidths.indices.contains(lines - 1) ? lineWidths[lines - 1] : firstLineWidth
        }
    }

    /// A line of this font as SwiftUI lays it: what a plain multi-line `Text` advances by, and
    /// what a row of the todo column is tall.
    ///
    /// Measured, not computed. Every formula from the font's own numbers was tried against
    /// `NSHostingView` at seven sizes — the rounded sum, the parts rounded one by one, TextKit's
    /// default line height, the bounding rect — and none matched at every size; the rounded sum
    /// gave 13 at 11pt where the text takes 14, and the Reels card folded half a line short.
    /// Two lines in a hosting view, halved, once per size, is the answer by construction.
    static func lineHeight(size: CGFloat) -> CGFloat {
        measuredLock.lock()
        defer { measuredLock.unlock() }
        if let height = measured[size] { return height }
        let view = NSHostingView(rootView: Text("a\nb").font(.system(size: size)).fixedSize())
        let height = view.fittingSize.height / 2
        measured[size] = height
        return height
    }

    private static let measuredLock = NSLock()
    private nonisolated(unsafe) static var measured: [CGFloat: CGFloat] = [:]

    /// Remembered, because a row asks three times per body and every row's body runs on every
    /// tick: typesetting 29 unchanged todos was over half of what the panel cost each second.
    static func metrics(_ text: String, width: CGFloat, size: CGFloat) -> Metrics {
        let key = "\(size)|\(width)|\(text)"
        measuredLock.lock()
        let known = remembered[key]
        measuredLock.unlock()
        if let known { return known }

        let fresh = typeset(text, width: width, size: size)
        measuredLock.lock()
        // ponytail: emptied rather than evicted; an LRU if a list ever outgrows it.
        if remembered.count > 512 { remembered.removeAll() }
        remembered[key] = fresh
        measuredLock.unlock()
        return fresh
    }

    private nonisolated(unsafe) static var remembered: [String: Metrics] = [:]

    private static func typeset(_ text: String, width: CGFloat, size: CGFloat) -> Metrics {
        let font = NSFont.systemFont(ofSize: size)
        let lineHeight = lineHeight(size: size)
        let single = Metrics(lineHeight: lineHeight, lineCount: 1, firstLineWidth: 0)
        guard width > 24, !text.isEmpty else { return single }

        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = text as NSString

        var start = 0
        var lines = 0
        var widths: [CGFloat] = []
        // The bound is a runaway guard, not a policy: a todo is occasionally a pasted receipt,
        // and the column sits in a scroll view that can take it.
        while start < attributed.length, lines < 60 {
            let fits = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard fits > 0 else { break }
            let line = ns.substring(with: NSRange(location: start, length: Int(fits)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            widths.append(NSAttributedString(string: line, attributes: [.font: font]).size().width)
            start += Int(fits)
            lines += 1
        }
        return Metrics(lineHeight: lineHeight, lineCount: max(lines, 1),
                       firstLineWidth: widths.first ?? 0, lineWidths: widths)
    }
}

/// The school, under the mail: the modules you are in the middle of and when each one closes.
///
/// The number on the heading is not the number of modules — it is how many projects still want
/// a rendu, which is the only figure here that is a size of work rather than a list of names.
struct EpitechColumn: View {
    @ObservedObject var hub: HubStore
    /// Whether ⌘ is down. The cards are a list while it is not, and every one of them opens
    /// what it is about while it is — the mail itself, the module's page on the intra. The
    /// same bargain the todo column makes.
    let commandHeld: Bool
    /// A plain click puts the panel away, like everywhere else on it.
    let onDismiss: () -> Void
    /// Off for an offscreen render, like the todo column's: `ImageRenderer` draws nothing
    /// inside a `ScrollView`.
    var scrolling = true

    /// The card under the pointer, which is the one ⌘ would open. On the column rather than
    /// the card, for the same reason the todo column keeps it here: a card is rebuilt every tick.
    @State private var hovered: String?

    var body: some View {
        HubColumn(title: "EPITECH",
                  count: hub.epitech?.projectsDue ?? 0,
                  showsZero: true,
                  tint: BlockTint.epitech,
                  fill: BlockTint.epitech.darkened(0.62),
                  badge: credits,
                  minRows: 3,
                  fills: true) {
            // The todo column's block, down to the scroll: a term of modules and a fortnight
            // of mail is longer than any screen, and the block is as tall as what is left of
            // the left column either way.
            if scrolling {
                ScrollView(.vertical) {
                    VStack(spacing: 8) { rows }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 8) { rows }
            }
        }
        .animation(TodoColumn.unroll, value: commandHeld)
    }

    /// Two to a row. The card is three facts wide — a name, what it pays, when it closes —
    /// and a term of twelve modules in one column of full-width cards was a scroll where a
    /// grid is a glance.
    private static let pair = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    @ViewBuilder private var rows: some View {
        if let snapshot = hub.epitech, !snapshot.modules.isEmpty {
            LazyVGrid(columns: Self.pair, spacing: 8) {
                ForEach(snapshot.modules) { module in
                    ModuleCard(module: module, lit: lit(module.id))
                        .epitechOpen(commandHeld: commandHeld, url: module.url,
                                     onHover: { hover(module.id, $0) }, onDismiss: onDismiss)
                }
            }
        } else {
            HubEmptyLine(text: hub.epitech == nil ? "No scan" : "No module open")
        }
    }

    private func lit(_ id: String) -> Bool { commandHeld && hovered == id }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    /// Banked, and what is left of the year's sixty — the only figure the heading carries.
    private var credits: String? {
        guard let credits = hub.epitech?.credits else { return nil }
        return "\(credits)+\(max(0, Epitech.creditsPerYear - credits))/\(Epitech.creditsPerYear)"
    }

}

/// What a card in the EPITECH block is, said in a word.
///
/// The panel's own pill, the one the tiles wear: 9pt bold on a wash of its own colour.
struct KindPill: View {
    let text: String
    let tint: Color

    /// Grey for a module — it is the block's own subject, and a colour on every card is a
    /// colour that means nothing.
    static let module = Color(white: 0.55)

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

extension View {
    /// What ⌘ does to a card in the EPITECH block: it opens what the card is about. Without
    /// ⌘ a click is a click anywhere else on the panel — it puts the panel away.
    ///
    /// The cards used to unroll under ⌘ instead, which answered a question the card had
    /// already answered: how many rendus, and when. What it could not do is show you the mail.
    func epitechOpen(commandHeld: Bool, url: URL? = nil, open: (() -> Void)? = nil,
                     onHover: @escaping (Bool) -> Void,
                     onDismiss: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onHover { onHover($0) }
            .onTapGesture {
                // The panel goes away either way. Opening a mail means reading it, and a
                // notification board still standing over what you opened is in the way.
                if commandHeld {
                    if let open { open() } else if let url { NSWorkspace.shared.open(url) }
                }
                onDismiss()
            }
    }

    /// The card every row of the EPITECH block sits on.
    func panelCard(lit: Bool = false) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(lit ? 0.2 : 0.07), lineWidth: 1)
            )
    }
}

/// One module, half the block wide: what it is called on my.epitech, what it pays in ECTS,
/// and the day it closes. Written exactly as the school writes it — "G5 - Blockchain & dApps"
/// is the module's name, and a card that title-cases or shouts it is showing a different word.
struct ModuleCard: View {
    let module: Epitech.Module
    /// ⌘ is down and the pointer is here: this is the card that would open.
    let lit: Bool

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // One line, whatever the name costs: twelve cards of equal height read as a term,
            // and a name that wraps makes its card taller than the one beside it. The long
            // ones shrink a fifth before they are cut.
            Text(module.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 2)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // my.epitech does not publish what a module is worth — the figures come from
                // the term's opening amphi, kept by hand in ~/.epitech/credits.json. A module
                // missing from that table says nothing rather than a made-up number.
                if let credits = module.credits {
                    Text("\(credits) CR")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 4)
                Text("due \(Self.day.string(from: module.end))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .panelCard(lit: lit)
    }
}

/// Everything that runs on its own and came back broken, in one bar over the fleet: a check
/// the phone gave up on, a scan that could not log in.
///
/// Over the middle rather than beside the block each failure came from. A warning that only
/// its own block can carry is a warning you find afterwards — the red word sat in a corner of
/// the left column, at the size of a footnote, next to a heading that reads the same whether
/// or not it is there. Over the fleet it is in the one place the eye already goes.
///
/// Off the panel entirely when nothing is wrong: a grey bar reporting that all is well is a
/// line of furniture you stop seeing, and the day it turns red you would not notice it had.
struct AlertsBlock: View {
    @ObservedObject var hub: HubStore

    /// One line of 11pt with room either side of it. Stated rather than worked out, because
    /// what hangs the bar over the fleet has to know it from outside — see `board`.
    static let height: CGFloat = 30

    /// What is broken, each source in its own words — which is also whether the bar is on the
    /// panel at all.
    ///
    /// Forced on to be looked at: `defaults write com.mr.fleet runsAlarm -bool true`.
    static func alerts(_ hub: HubStore) -> [String] {
        var out: [String] = []
        // Firestore first: when it is down, every figure on the panel is from the last fetch
        // that worked, and nothing else here can be trusted to be current either.
        if let failure = hub.failure {
            switch failure {
            case "offline": out.append("firestore offline — mail and todos are from the last fetch")
            case "not saved": out.append("todo not saved — firestore refused the write")
            default: out.append("firestore: \(failure)")
            }
        }
        if let failure = hub.epitech?.failure { out.append(failure) }
        let failed = hub.failedRuns.count
        if failed > 0 { out.append(failed == 1 ? "1 run failed" : "\(failed) runs failed") }
        if out.isEmpty, UserDefaults.standard.bool(forKey: "runsAlarm") { out.append(demo) }
        return out
    }

    /// What the bar says when it has been switched on by hand: one of the failures that can
    /// really happen, rather than the word "test" — the point of looking at it is to see what
    /// the day it fires will look like, and a bar reading "test" shows the frame and none of
    /// the sentence.
    ///
    /// Drawn once, at launch: `alerts` is read on every tick, and a line that picks again each
    /// time would be a bar nobody can read.
    private static let demo = [
        "epitech session expired — log in again",
        "epitech scan failed — my.epitech did not answer",
        "outlook token expired — no mail since the last run",
        "edsquare unreachable — no timetable this run",
        "discord token expired — announcements not read",
        "agenda not writable — deadlines were not filed",
        "scan 2d old — nothing here is current",
        "1 run failed",
    ].randomElement() ?? "1 run failed"

    /// Built like every other block on the panel: the name on its chip at the top left, the
    /// frame the width of what it heads. What is wrong goes in the middle of the line, on a
    /// ground of its own — the same place, and the same treatment, as the state legend on the
    /// fleet's heading right under it. A sentence pinned to the left would sit under the name
    /// and read as part of it.
    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Text("ALERT")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3.2)
                    .foregroundStyle(SessionState.running.tint)
                    .titleGround()
                Spacer(minLength: 3)
            }

            HStack(spacing: 8) {
                // The one mark on the panel that asks a question rather than reporting: what
                // is behind it is a thing to go and look at, not a number to read.
                Text("?")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SessionState.running.tint)
                    .frame(width: 16, height: 16)
                    .background(SessionState.running.tint.opacity(0.18), in: Circle())
                Text(Self.alerts(hub).joined(separator: "  \u{00B7}  "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SessionState.running.tint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SessionState.running.tint.opacity(0.7), lineWidth: 1))
        }
        .frame(height: Self.height)
        // The fleet's own spread, so the two frames end on the same line either side. Tinted
        // rather than coloured, like every other block: at the tint's own strength the bar was
        // a red slab across the panel, and the words on it were the quietest thing on it.
        .blockFrame(SessionState.running.tint, fill: SessionState.running.tint.darkened(0.58),
                    spread: 26, bottomSpread: 8, radius: 8)
        // The whole bar, frame and sentence included — not the name alone as on a block that
        // is merely stale. This one has nothing else to say, so the pulse is all of it.
        .blinking(true)
    }
}

