import SwiftUI

extension SessionState {
    var tint: Color {
        switch self {
        case .running: return Color(red: 1.00, green: 0.35, blue: 0.32)
        case .ready: return Color(red: 0.24, green: 0.82, blue: 0.35)
        case .awaitingAnswer: return Color(red: 0.27, green: 0.62, blue: 1.00)
        // The panel's one amber, shared with the sub-agent pill, and it means the same thing in
        // both places: something is happening that is not yours to answer.
        case .apiError: return Color(red: 1.00, green: 0.62, blue: 0.15)
        }
    }

    var label: String {
        switch self {
        case .running: return "WORKING"
        case .ready: return "READY"
        case .awaitingAnswer: return "NEEDS YOU"
        case .apiError: return "API ERROR"
        }
    }
}

struct OverlayView: View {
    @ObservedObject var controller: AppController
    /// Offscreen `ImageRenderer` passes never materialise lazy content inside a ScrollView,
    /// so `--render` drops the scroll container to draw every tile.
    var eagerLayout = false

    /// Fixed tiles per row and fixed width, rather than adaptive, so a partial last row
    /// (and a one-session fleet) still centres instead of hugging the left edge.
    ///
    /// Two, and never three. A third column used to appear once a fleet outgrew six, and the
    /// width it took is now the mail and todo columns either side of it — the middle of the
    /// panel is no longer the whole panel.
    private static let tilesPerRow = 2
    /// How dark the panel sits over your desktop. Lower shows more of what's behind it.
    private static let tintOpacity: Double = 0.80

    private let tileWidth: CGFloat = 310
    /// Wider than it looks like it needs to be: the hover glow is a 16pt shadow, and the
    /// neighbouring tile is opaque and drawn after, so a tighter gap eats the glow.
    private let tileSpacing: CGFloat = 26

    /// The grid's own width, pinned rather than flexible: it is the middle of three columns
    /// now, and a middle that resizes with the fleet would slide the mail and todo columns
    /// around every time a session started.
    private var centerWidth: CGFloat { tileWidth * CGFloat(Self.tilesPerRow)
        + tileSpacing * CGFloat(Self.tilesPerRow - 1) }
    /// Narrow on purpose. These two are what is on your plate, not what you are working on —
    /// they earn a glance each, and anything wider starts competing with the fleet.
    private let sideWidth: CGFloat = 250

    /// How the leftover width is shared out: 2 : 3 : 3 : 2, edges to insides. Ratios rather
    /// than points, so the balance holds on a laptop screen and on a 34-inch one — a fixed
    /// margin on a wide display would pin the columns to the bezel and leave the middle adrift.
    private static let edgeWeight = 2
    private static let innerWeight = 3

    /// How far below the fleet the two side columns start. A podium: the sessions are what the
    /// panel is for, and standing them a step above what is merely waiting says so before a
    /// word is read.
    private static let podiumDrop: CGFloat = 72

    /// How far the hover glow reaches past a tile: a 16pt shadow, and the 1.5% scale on a
    /// 310pt card.
    private static let glowRoom: CGFloat = 22

    var body: some View {
        ZStack {
            // Flat scrim rather than a live blur. Two reasons, and the second one is why the
            // frosted version was tried and dropped: a full-screen material is continuous GPU
            // work in an app that exists to save power, and macOS's behind-window blur has a
            // fixed radius — there is no dialling it down. It obliterates what is behind it or
            // it is not on. A plain black wash keeps your windows recognisable underneath,
            // which is the point of a panel that floats over your work.
            Color.black.opacity(Self.tintOpacity)
                .ignoresSafeArea()

            board(scrolling: !eagerLayout)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 100)
        }
        // The one thing in the panel that is not about Claude at all. It earns the space only
        // when the machine is actually short of memory, and it is gone the rest of the time.
        .overlay(alignment: .top) {
            MemoryStrip(reaper: controller.reaper).padding(.top, 65)
        }
        // Anything not claimed by a tile dismisses, matching Esc. Tiles are Buttons and
        // consume their own taps, so this only fires on the surrounding space.
        .contentShape(Rectangle())
        .onTapGesture { controller.hidePanel() }
    }

    /// Flexible space of a given weight. Adjacent `Spacer`s in an HStack split the slack
    /// equally, so three of them are half again as wide as two — which is the only way to say
    /// "flex-grow" in SwiftUI.
    @ViewBuilder private func gap(_ weight: Int) -> some View {
        ForEach(0 ..< weight, id: \.self) { _ in Spacer(minLength: 8) }
    }

    /// A ScrollView claims hit-testing across its whole area, so taps landing in the gaps
    /// between tiles never reach the outer gesture. This puts a dismiss target behind them.
    private var dismissLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { controller.hidePanel() }
    }

    private func rows(of sessions: [Session]) -> [[Session]] {
        stride(from: 0, to: sessions.count, by: Self.tilesPerRow).map {
            Array(sessions[$0 ..< min($0 + Self.tilesPerRow, sessions.count)])
        }
    }

    /// The whole panel below the header, across: the mail worth reading, the fleet, the list of
    /// things to do.
    ///
    /// The sides are not sessions and never will be — they are the other two things this
    /// machine knows are waiting for you, read from the same Firestore the phone uses. They sit
    /// out here rather than above or below the grid because a glance across is free and a
    /// glance down the page is not: the fleet stays exactly where it has always been, in the
    /// middle, and the sides are only in your eye if you look for them.
    ///
    /// The four gaps are the layout — one at each edge, one between each pair — and they carry
    /// all of the flex, since the three blocks themselves are fixed. The inside gaps are half
    /// again as wide as the outside ones, so the columns sit slightly out towards the edges of
    /// the screen: a column too close to the grid reads as part of it, and it is not — it is
    /// the other half of your day.
    ///
    /// Both vanish together on a machine with no key in the Keychain, so the grid re-centres
    /// instead of sitting between two empty apologies.
    private func board(scrolling: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gap(Self.edgeWeight)
            if controller.hub.isConfigured {
                MailColumn(hub: controller.hub)
                    .frame(width: sideWidth)
                    .padding(.top, Self.podiumDrop)
                gap(Self.innerWeight)
            }
            fleet(scrolling: scrolling).frame(width: centerWidth)
            if controller.hub.isConfigured {
                gap(Self.innerWeight)
                TodoColumn(hub: controller.hub,
                           commandHeld: controller.commandHeld,
                           onDismiss: { controller.hidePanel() })
                    .frame(width: sideWidth)
                    .padding(.top, Self.podiumDrop)
            }
            gap(Self.edgeWeight)
        }
        .frame(maxWidth: .infinity)
        // Room for the glow on the top row — the ScrollView clips to its bounds, and the
        // shadow reaches 16pt out on hover.
        .padding(.top, 26)
        .background(dismissLayer)
    }

    /// The tiles with the prompt bubble immediately under them, as one block. The bubble rides
    /// with the grid rather than being pinned to the bottom of the screen: on a fleet of three
    /// sessions the screen bottom is half a metre of empty black away from anything you are
    /// looking at, and a control down there reads as unrelated to the panel above it.
    private func fleet(scrolling: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fleetHeading
            // The same gap the side columns leave under their own rule, plus the room the
            // top row's hover glow needs — it reaches 16pt up, and the rule is right there.
            if scrolling {
                // Only the tiles scroll. The mail and todo columns either side stayed put
                // while the whole board slid under them, which read as the panel coming apart.
                // No indicator: a bar down the middle of the panel is furniture, and the
                // tiles cut off at the bottom edge say there is more just as well.
                // The negative padding is the room the hover glow needs. A ScrollView clips
                // to its own bounds, and the grid is exactly as wide as the column, so the
                // outer tiles had their glow — and the edge of the card itself, once scaled —
                // sliced off. The container is widened past the column and the content is
                // pushed back in by the same amount, which leaves the tiles where they were
                // and the clip out of reach.
                ScrollView(.vertical) {
                    // Real padding at the top rather than a negative inset on the container:
                    // the heading has to clip what scrolls under it, so the glow's room is
                    // taken inside the scroll view instead of over the rule above it.
                    grid.padding(.horizontal, Self.glowRoom)
                        .padding(.top, 18)
                        .padding(.bottom, 44)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .padding(.horizontal, -Self.glowRoom)
            } else {
                grid.padding(.top, 18).padding(.bottom, 20)
            }
        }
    }

    /// The fleet's own column heading, built like the two either side of it: a name, a rule the
    /// width of what it heads, and the count on the right.
    ///
    /// This used to be a banner across the top of the panel — the name, then "1 of 4 needs your
    /// input" at thirty points. Two things were wrong with it. It was a sentence where the
    /// tiles underneath already say the same thing in colour, and it sat above all three
    /// columns while naming only the middle one, so the panel read as one thing with a title
    /// rather than three lists side by side.
    ///
    /// The states go in the middle of the rule rather than beside the name, because they
    /// describe the tiles below rather than the heading itself — and centred on the line they
    /// belong to nothing in particular, which is right: they are a key, not a count.
    private var fleetHeading: some View {
        ZStack {
            HStack(spacing: 8) {
                Text("CLAUDE CODE FLEET")
                    .font(.system(size: 11, weight: .semibold))
                    // Tighter than the two side headings, which are one short word each. At
                    // their tracking this one runs into the legend beside it.
                    .tracking(2.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 4)
                if !controller.sessions.isEmpty {
                    Text("\(controller.sessions.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }

            // On a ground of its own, like everything else on the panel that is a thing rather
            // than a label. Four dots floating on the scrim read as specks; the same four on a
            // card read as a key. Kept as small as the dots allow — it is furniture, not a
            // control, and it sits on a line with a name and a count either side of it.
            HStack(spacing: 9) {
                legend(.awaitingAnswer)
                legend(.ready)
                legend(.running)
                legend(.apiError)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
                .offset(y: 9)
        }
    }

    private func tiles(_ sessions: [Session]) -> some View {
        VStack(spacing: tileSpacing) {
            ForEach(rows(of: sessions), id: \.first?.id) { row in
                HStack(alignment: .top, spacing: tileSpacing) {
                    ForEach(row) { session in
                        SessionTile(session: session) {
                            controller.activate(session)
                        }
                        .frame(width: tileWidth)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Every tile, in rows of two. However long the fleet gets, it grows downwards — the
    /// panel's own vertical scroll carries it.
    private var grid: some View {
        tiles(controller.sessions).background(dismissLayer)
    }

    /// Four dots, and no words.
    ///
    /// The words were there to teach the colours and they had stopped teaching anybody
    /// anything — the tiles carry them, spelled out, on every pill. What is left is the palette
    /// itself, which is worth having on the heading for a different reason: it says how many
    /// states there are, so a colour you have not seen this week still reads as one of a set
    /// rather than as something new.
    private func legend(_ state: SessionState) -> some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
    }
}

/// The bubble under the grid: the prompt field, and what came back from what you sent.
///
/// The field is *always* there and always has the caret. No key opens it, because a key to
/// open it is a key you have to press before your dictation shortcut — and the shortcut is
/// meant to be the only thing you touch. Everything the panel has to say afterwards is said on
/// the line underneath, so the field never moves or goes away while you are aiming at it.
struct PromptBar: View {
    @ObservedObject var prompt: PromptController
    /// Offscreen, the field is drawn as the text it shows rather than as a field.
    /// `ImageRenderer` cannot rasterise a `TextField` — it puts a yellow bar with a "no entry"
    /// sign where one should be — so every screenshot of this panel had a broken control in the
    /// middle of it. This draws what the field looks like at rest, which is what a screenshot
    /// of a panel nobody has typed into should show anyway.
    var eager = false
    /// The field is only useful with the keyboard in it, and a dictation tool pasting from
    /// outside lands wherever focus is — which has to be here.
    @FocusState private var editing: Bool

    /// Where the field and a long answer wrap.
    private static let maxTextWidth: CGFloat = 460

    var body: some View {
        composer
    }

    // MARK: - Composing

    /// The prompt on its way out: an empty field with the caret in it, waiting for you to
    /// type — or for a dictation tool of your own to paste into it.
    ///
    /// Nothing is sent until Return. Project names are what a pasted transcript gets wrong
    /// most, and that is exactly the word that decides which session the prompt lands in — so
    /// it is worth the half second to read what is in the field before sending it.
    private var composer: some View {
        let tint = Self.restingTint
        let bubble = Self.bubble(wrapping: true)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                dot(line?.tint ?? tint)

                // Vertical axis so a long paragraph wraps instead of scrolling off the side.
                // Return is claimed by the window rather than `onSubmit`, so it submits even
                // on the multi-line field — see `PanelWindow.onReturn`.
                // Written by hand rather than `$prompt.field.draft`: the controller holds the
                // field as a constant, and a projected binding cannot write through one.
                // Changes still reach the view — the controller republishes them.
                if eager {
                    Text(prompt.field.draft.isEmpty ? Self.placeholder : prompt.field.draft)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(prompt.field.draft.isEmpty ? 0.3 : 0.95))
                        .frame(width: Self.maxTextWidth, alignment: .leading)
                } else {
                    TextField(Self.placeholder, text: Binding(get: { prompt.field.draft },
                                                              set: { prompt.field.draft = $0 }),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.95))
                        // Not the resting tint: a grey caret on a near-black field is hard to
                        // spot, and the caret is the one thing that has to be obvious here.
                        .tint(.white.opacity(0.8))
                        .lineLimit(1 ... 8)
                        .frame(width: Self.maxTextWidth, alignment: .leading)
                        .focused($editing)
                }
            }

            if let line {
                Text(line.text)
                    .font(.system(size: line.emphasis > 0.5 ? 12 : 11))
                    .foregroundStyle(.white.opacity(line.emphasis))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: Self.maxTextWidth, alignment: .leading)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        // Near-solid and darker than the scrim, rather than the white wash it used to be. That
        // wash let the desktop through, and text you are about to *edit* has to sit on a
        // background of its own — a caret and a half-written sentence over someone's browser
        // are hard to read and read as decoration rather than as a field.
        .background(Self.fieldBackground, in: bubble)
        .overlay(bubble.strokeBorder(tint.opacity(0.45), lineWidth: 1))
        // Focus is not decoration here: a field without it swallows what you type, and a paste
        // from a dictation tool lands in whatever app holds the keyboard instead. Asked for on
        // every open, not just the first: the panel's window and its view tree are built once
        // and reused, so `onAppear` fires for the first showing only.
        .onAppear { editing = true }
        .onChange(of: prompt.field.focusRequests) { editing = true }
    }

    private static let placeholder = "Type your prompt"

    /// Grey, deliberately: the three tints above the field each mean something about a session,
    /// and a field sitting at rest means nothing at all. Borrowing the blue made an empty
    /// composer read as a fourth thing needing an answer. Colour comes back only on the status
    /// line, once you have actually sent something.
    private static let restingTint = Color.white.opacity(0.35)

    /// A shade under the tiles' own `0.07` grey, so the field reads as recessed into the panel
    /// rather than floating on it, and opaque enough that nothing behind the panel shows through.
    private static let fieldBackground = Color(red: 0.04, green: 0.04, blue: 0.055)
        .opacity(0.97)

    private func dot(_ tint: Color) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .opacity(0.85)
            .padding(.top, 5)
    }

    /// Capsule while it is a one-line status, rounded rectangle once it is a paragraph.
    private static func bubble(wrapping: Bool) -> AnyInsettableShape {
        wrapping
            ? AnyInsettableShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            : AnyInsettableShape(Capsule(style: .continuous))
    }

    private struct Line {
        var text: String
        var tint: Color
        var emphasis: Double
    }

    /// The line under the field, and nil when there is nothing to say. Return and Esc are not
    /// worth a permanent line of their own: an empty field with a caret in it is already an
    /// invitation, and the panel says how to dismiss itself above the tiles.
    private var line: Line? {
        switch prompt.status {
        case .idle:
            return nil
        case .routing:
            return Line(text: "Working out where that goes\u{2026}",
                        tint: SessionState.awaitingAnswer.tint, emphasis: 0.6)
        case .thinking:
            return Line(text: "Thinking\u{2026}", tint: SessionState.awaitingAnswer.tint,
                        emphasis: 0.6)
        case .launched(let project):
            return Line(text: "Started a Claude Code session in \(project).",
                        tint: SessionState.ready.tint, emphasis: 0.85)
        case .answer(let text):
            return Line(text: text, tint: SessionState.ready.tint, emphasis: 0.92)
        case .failed(let why):
            return Line(text: why, tint: SessionState.running.tint, emphasis: 0.8)
        }
    }
}

/// One session, read at a glance: the name, the state border, and — only while it is
/// working — the single step in flight. Everything else is a distraction at this size;
/// `--scan` is there when you want the details.
struct SessionTile: View {
    let session: Session
    let onSelect: () -> Void

    /// Sub-agent work gets its own colour rather than the state tint. The border already says
    /// what the session is; this says the work is happening somewhere else, on someone else's
    /// clock — and orange reads as "in flight" next to a red that means "this one is busy".
    static let subagentTint = Color(red: 1.00, green: 0.62, blue: 0.15)

    @State private var hovering = false

    /// Fixed so the name's 30% line is the same on every tile, whatever the history under it.
    private static let height: CGFloat = 186
    /// Roughly the name's line height at its font size, to centre it on that 30% mark.
    /// Tracks `name`'s point size — if one moves the other has to.
    private static let nameLine: CGFloat = 37

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    // The name sits with its centre 30% down the tile, so every tile's name
                    // lands on the same line however much history is under it.
                    Spacer().frame(height: Self.height * 0.30 - Self.nameLine / 2)
                    name
                    // The space above flexes and the space below is fixed, so the history sits
                    // low in the tile — anchored near the bottom edge rather than centred
                    // between it and the name.
                    Spacer(minLength: 8)
                    rail
                    subagent
                    step
                    Spacer().frame(height: 12)
                }
                .padding(12)
                // Without this the stack is only as tall as its content, the flexible spacer
                // above the history has nothing to expand into, and the slack ends up below
                // the tile's content instead of above it — which is why the history sat high
                // whatever the spacers said.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                HStack(alignment: .top, spacing: 7) {
                    number
                    path
                    Spacer(minLength: 6)
                    subagentPill
                    statePill
                }
                .padding(11)
            }
            .frame(height: Self.height, alignment: .top)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(session.state.tint, lineWidth: 2.5)
            )
            // Order matters. `scaleEffect` renders the card into an offscreen buffer sized to
            // its own bounds, so a shadow applied *before* it gets baked into that buffer and
            // clipped off at the card's edges — which is exactly the sliced-off glow you see
            // on hover. Grouping first, scaling, then casting the shadow keeps it outside.
            .compositingGroup()
            .scaleEffect(hovering ? 1.015 : 1.0)
            .shadow(color: session.state.tint.opacity(hovering ? 0.45 : 0.18),
                    radius: hovering ? 16 : 8)
            // Without this the card snaps to its hovered size in one frame, which reads as a
            // flicker rather than as a response to the pointer.
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var name: some View {
        Text(session.dirName)
            .font(.system(size: 31, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The session's recent history, oldest at the top: what you asked, what it ran, what it
    /// said back. One line each — the sequence is the point, not any single line's detail.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The tile is a fixed height, so the sub-agent line has to come out of somewhere:
            // it takes the oldest rail line rather than pushing the whole stack past the
            // bottom edge. What a sub-agent is doing now beats one more finished step.
            let room = session.subagentLine == nil ? Config.railLineCount
                                                   : Config.railLineCount - 1
            let lines = session.steps.suffix(room)
            if lines.isEmpty {
                Text("No conversation yet")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            } else {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(glyph(for: line.kind))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(tint(for: line.kind))
                        Text(line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(line.kind == .tool ? 0.45 : 0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        // No trailing spacer: the rail must stay exactly as tall as its lines, or it absorbs
        // the tile's slack itself and the spacers positioning it have nothing left to give.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func glyph(for kind: PreviewLine.Kind) -> String {
        switch kind {
        case .user: return ">"
        case .assistant: return "*"
        case .tool: return "-"
        }
    }

    private func tint(for kind: PreviewLine.Kind) -> Color {
        switch kind {
        case .user: return Color(red: 0.42, green: 0.70, blue: 1.00)
        case .assistant: return .white.opacity(0.5)
        case .tool: return .white.opacity(0.3)
        }
    }

    /// The session's number, top left. Two sessions in the same directory are told apart by
    /// their tiles' contents and nothing else; this is the one thing on a tile that is short
    /// enough to say out loud and belongs to that session alone.
    @ViewBuilder private var number: some View {
        if session.number > 0 {
            Text("\(session.number)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    /// Top left, and only when it says something the name doesn't already — a project sitting
    /// at ~/self/<name> gets nothing here.
    @ViewBuilder private var path: some View {
        if let path = session.subPath {
            Text(path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// Pinned under the rail: the step still in flight, which by definition has no result yet
    /// and so never appears in the history above it.
    @ViewBuilder private var step: some View {
        if let step = session.currentStep {
            HStack(alignment: .top, spacing: 6) {
                Text("»")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(step)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(session.state.tint.opacity(0.95))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Between the history and the step: the sub-agent this session handed the work to, and
    /// what it is doing right now. Nothing above it says a word about it — the sub-agent's
    /// steps go in its own transcript, so without this line the tile looks stalled.
    @ViewBuilder private var subagent: some View {
        if let line = session.subagentLine {
            HStack(alignment: .top, spacing: 6) {
                Text("↳")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Self.subagentTint.opacity(0.95))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Sits next to the state pill while sub-agents are out. The pill says the session is
    /// working; this says who is actually doing the work.
    @ViewBuilder private var subagentPill: some View {
        let running = session.subagents.count
        if running > 0 {
            Text(running == 1 ? "SUB-AGENT" : "SUB-AGENTS ×\(running)")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Self.subagentTint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Self.subagentTint.opacity(0.14), in: Capsule())
        }
    }

    private var statePill: some View {
        Text(session.state.label)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(session.state.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(session.state.tint.opacity(0.14), in: Capsule())
    }
}

/// `InsettableShape` has an associated type, so a shape cannot simply be returned from an
/// `if`. This is the usual type-erasing wrapper, kept minimal: `strokeBorder` is the only
/// reason the insettable half is needed at all.
struct AnyInsettableShape: InsettableShape {
    private let makePath: @Sendable (CGRect) -> Path
    private let makeInset: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        makePath = { shape.path(in: $0) }
        makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { makePath(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}


/// What is holding the memory, while the machine is short of it.
///
/// The counterpart to the reaper, and the reason the reaper can afford to be so conservative:
/// everything it refuses to kill on its own — your browser, a build in progress, an app you
/// happen to have open — shows up here instead, with a ✕ next to it. The machine picks off
/// only what it can prove nobody is using; the judgement calls come to you, at the moment you
/// were going to look at the panel anyway.
struct MemoryStrip: View {
    @ObservedObject var reaper: Reaper

    private var amber: Color { Color(red: 1.00, green: 0.62, blue: 0.15) }

    var body: some View {
        if reaper.pressure.isTight && !reaper.hogs.isEmpty {
            HStack(spacing: 14) {
                Text(headline)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(amber)

                ForEach(reaper.hogs) { hog in
                    HogPill(hog: hog, tint: amber)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(amber.opacity(0.10))
                    .overlay(Capsule().stroke(amber.opacity(0.30), lineWidth: 1))
            )
        }
    }

    /// Swap, not free RAM: free RAM is near zero on every healthy Mac and would cry wolf
    /// permanently. Swap in use is the number that tracks how slow the machine actually feels.
    private var headline: String {
        let used = Double(MemoryPressure.swap().used) / 1_073_741_824
        let label = reaper.pressure == .critical ? "MEMORY CRITICAL" : "MEMORY PRESSURE"
        return String(format: "%@ · %.1f GB SWAPPED", label, used)
    }
}

private struct HogPill: View {
    let hog: Hog
    let tint: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(hog.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(hog.sizeLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))

            if hog.reapable {
                // Already condemned: saying so is more useful than offering a ✕ for something
                // that is about to go by itself.
                Text("auto")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
            } else {
                Button { Reaper.dismiss(pid: hog.pid) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.35))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
        }
    }
}
