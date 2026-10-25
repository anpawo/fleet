import SwiftUI

extension SessionState {
    var tint: Color {
        switch self {
        case .running: return Color(red: 1.00, green: 0.35, blue: 0.32)
        case .ready: return Color(red: 0.24, green: 0.82, blue: 0.35)
        case .awaitingAnswer: return Color(red: 0.27, green: 0.62, blue: 1.00)
        // Amber is the machine's own colour here and in the stall strip: something is going
        // wrong that is not yours to answer.
        case .apiError: return Color(red: 1.00, green: 0.62, blue: 0.15)
        // The panel's one purple, shared with the sub-agent pill: agents are out. On the border
        // it says the session is nonetheless yours to type into — the work is happening on
        // threads that are not the one you would be talking to.
        case .delegated: return Color(red: 0.70, green: 0.48, blue: 1.00)
        // Yellow, not the amber beside it: amber is a request failing, yellow is Fleet holding
        // the session on purpose until memory frees up.
        case .paused: return Color(red: 1.00, green: 0.88, blue: 0.20)
        // No hue at all: every one is spoken for by a state or a block, and a blank page is
        // what the session is.
        case .fresh: return .white
        }
    }

    var label: String {
        switch self {
        case .running: return "WORKING"
        case .ready: return "READY"
        case .awaitingAnswer: return "NEEDS YOU"
        case .apiError: return "API ERROR"
        case .delegated: return "BACKGROUND-TASK"
        case .paused: return "PAUSED"
        case .fresh: return "NEW"
        }
    }
}

struct OverlayView: View {
    @ObservedObject var controller: AppController
    /// Offscreen `ImageRenderer` passes never materialise lazy content inside a ScrollView,
    /// so `--render` drops the scroll container to draw every tile.
    var eagerLayout = false


    /// EPITECH open under the pointer — see `EpitechColumn.open`. Seeded from `--school-open`
    /// so a render can show it.
    @State private var schoolOpen = CommandLine.arguments.contains("--school-open")
    /// MAIL's list, measured — see `reelsRoom`.
    @State private var mailNeed: CGFloat = 0


    /// Fixed tiles per row and fixed width, rather than adaptive: a partial last row, and a
    /// one-session fleet, start at the same left edge as every full row rather than drifting
    /// to the middle. A lone tile that centres itself reads as a different column each time
    /// the fleet is odd-numbered.
    ///
    /// Three (asked 2026-10-15), on tiles narrow enough that the side columns keep their width.
    static let tilesPerRow = 3

    private let tileWidth = SessionTile.width
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
    private let sideWidth: CGFloat = 288

    /// A block folding to its heading, or growing into the room one left: slow enough to see
    /// where the room went.
    static let fold: Animation = .easeInOut(duration: 0.35)

    /// The leftover width goes to the two edges, equally.
    private static let edgeWeight = 2

    /// What the eye sees between any two blocks, across and down — the one margin on the
    /// panel, asked for on 2026-09-27.
    static let frameGap: CGFloat = 25

    /// Between a side column and the fleet: the side frame reaches 13pt past its column, the
    /// fleet's 26pt past its grid.
    private static let innerGap: CGFloat = frameGap + 13 + fleetSpread

    /// How far the fleet's frame reaches past its grid either side: a tile's hover glow
    /// reaches 22pt, and a frame inside that is a line the cards wipe over.
    static let fleetSpread: CGFloat = 26
    /// The fleet's frame, outline to outline — which the ALERT bar over it matches.
    private var fleetFrameWidth: CGFloat { centerWidth + 2 * Self.fleetSpread }

    /// How far over the fleet's top ALERT sits: one heading line and one block's gap.
    static let overLine: CGFloat = 14 + blockGap

    /// The one space between two blocks of a side column. A frame reaches 13pt past its
    /// content at the bottom and at the top of the next.
    private static let blockGap: CGFloat = frameGap + 26

    /// How far the hover glow reaches past a tile: a 16pt shadow, and the 1.5% scale on a
    /// 310pt card.
    private static let glowRoom: CGFloat = 22

    /// How far a block's frame reaches past its content either side — `blockFrame`'s own
    /// default spread.
    static let blockSpread: CGFloat = 13

    /// What the panel leaves above its first block — 100 over the board and 26 more inside it
    /// — and, now, under its last one. The same gap at both ends: a column that stopped where
    /// the screen did read as the panel having been cut off rather than laid out.
    static let inset: CGFloat = 126

    /// What the menu bar takes off the top of the window, which is the whole screen. Zero on
    /// a screen that has none.
    static var menuBar: CGFloat {
        let screen = OverlayWindowController.activeScreen()
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    /// As tall as the screen has room for between those two gaps — the ceiling a column
    /// scrolls or is cut off under, rather than a height it takes.
    /// What a block is told to be, against the `columnHeight` its column is clipped to: a
    /// block's frame is drawn `blockSpread` past its content on every side — see `blockFrame`
    /// — and a block as tall as the clip lost its own bottom edge to it.
    static var blockHeight: CGFloat { columnHeight - blockSpread }

    /// Measured as the panel goes up — see `OverlayWindowController.show` — not at every pass
    /// over the body: finding the screen is a round trip to the window server, and a pass
    /// asks six times. It was 2 ms of the 11 a click on a group took (sampled 2026-10-12).
    static var columnHeight: CGFloat = measuredColumnHeight()

    static func measuredColumnHeight() -> CGFloat {
        let screen = OverlayWindowController.activeScreen()
        // The window is the whole screen, menu bar and dock included, so the insets are
        // measured off that. A dock at the bottom eats into the gap rather than adding to it.
        let dock = screen.visibleFrame.minY - screen.frame.minY
        return max(240, screen.frame.height - inset - max(inset, dock))
    }

    var body: some View {
        ZStack {
            // Echo's veil (asked 2026-10-20): the screen blurred 4 pt under the black wash, each
            // block a frosted glass on it — see `Glass`. The flat wash of 2026-08-10 was there
            // because macOS's blur has one radius; Echo's private filter dials it.
            Veil()
                .ignoresSafeArea()

            board(scrolling: !eagerLayout)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 100)
        }
        // Anything not claimed by a tile dismisses, matching Esc. Tiles are Buttons and
        // consume their own taps, so this only fires on the surrounding space.
        //
        // Except when the panel let itself in: an alert that a stray click can take away is an
        // alert you will lose without noticing, and the click that loses it is the one you were
        // already making when it appeared.
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

    private func rows<T>(of items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: Self.tilesPerRow).map {
            Array(items[$0 ..< min($0 + Self.tilesPerRow, items.count)])
        }
    }

    /// What REELS may be at rest, pane included, out of `below` — the left column under the
    /// memory: what is left once MAIL has its list and EPITECH its heading line. A heading line
    /// is 14, as `overLine` counts it; MAIL's list sits 17 under its own. Nothing until the
    /// list has been measured, or REELS would open for a frame before the mails shut it.
    private func reelsRoom(_ below: CGFloat) -> CGFloat {
        let hub = controller.hub
        guard hub.mailEmpty || mailNeed > 0 else { return 0 }
        let mail = hub.mailEmpty ? 14 : 14 + 17 + mailNeed
        return below - Self.blockGap - mail - Self.overLine + 2 * Self.blockSpread
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
    /// The three blocks are fixed and `frameGap` apart; the two edges carry all of the flex.
    ///
    /// Both vanish together on a machine with no key in the Keychain, so the grid re-centres
    /// instead of sitting between two empty apologies.
    private func board(scrolling: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gap(Self.edgeWeight)
            if controller.hub.isConfigured {
                // The step the podium leaves above the mail is exactly where the machine's own
                // state belongs: the one thing on the panel that is not about Claude at all,
                // in the corner, at the width of the column it sits over. A minimum rather
                // than a height — under pressure the hogs need more rows, and an alert that
                // shoves the column down is an alert doing its job.
                // One gap, three blocks: the machine's own two lines, the mail and the
                // school. Every space between them is the same space — a column whose gaps
                // vary reads as groups nobody meant to make.
                // One block takes what is left of the column once the memory has had its
                // line: EPITECH under the pointer, MAIL the rest of the time, REELS whatever
                // the mails leave (asked 2026-10-15). The others are their heading, or as tall
                // as what they hold. Each scrolls inside its share, so none can push another
                // off the bottom.
                let hub = controller.hub
                let school = schoolOpen && !hub.schoolEmpty
                VStack(alignment: .leading, spacing: Self.blockGap) {
                    MemoryStrip(reaper: controller.reaper,
                                commandHeld: controller.commandHeld)
                    // Read under the memory, which grows under pressure: what is left there
                    // does not move when REELS opens into it.
                    GeometryReader { below in
                        VStack(alignment: .leading, spacing: Self.blockGap) {
                            ReelBlock(hub: hub, commandHeld: controller.commandHeld,
                                      limit: Self.columnHeight / 3,
                                      room: school ? 0 : reelsRoom(below.size.height))
                            GeometryReader { space in
                                let free = space.size.height - Self.blockGap
                                VStack(alignment: .leading, spacing: Self.blockGap) {
                                    // Under an open school, three sevenths at most. Otherwise
                                    // all of it but EPITECH's heading line and the gap over
                                    // it — a limit counts the frame, which reaches
                                    // `blockSpread` past the block top and bottom.
                                    MailColumn(hub: hub,
                                               commandHeld: controller.commandHeld,
                                               scrolling: !eagerLayout,
                                               limit: school ? max(0, free * 3 / 7)
                                                   : space.size.height - Self.overLine + 2 * Self.blockSpread,
                                               natural: $mailNeed)
                                    EpitechColumn(hub: hub,
                                                  commandHeld: controller.commandHeld,
                                                  onDismiss: controller.dismiss,
                                                  scrolling: !eagerLayout,
                                                  open: $schoolOpen)
                                        .frame(maxHeight: school ? .infinity : nil, alignment: .top)
                                }
                                .frame(height: space.size.height, alignment: .top)
                            }
                        }
                        .frame(height: below.size.height, alignment: .top)
                    }
                }
                .animation(Self.fold, value: hub.mailEmpty)
                .animation(Self.fold, value: hub.schoolEmpty)
                // A panel put away with the pointer on the school brings no hover-out back.
                .onChange(of: controller.isPanelVisible) { _, shown in
                    if !shown { schoolOpen = false }
                }
                .frame(height: Self.blockHeight, alignment: .top)
                // Cut off at the panel's own bottom gap rather than run off the screen. The
                // widening either side of the clip is the room a block's frame takes past its
                // content — see `blockFrame` — which a clip at the column's width would shave.
                .frame(width: sideWidth, height: Self.columnHeight, alignment: .top)
                // The clip is only ever meant to land at the foot of the column, so it is
                // opened out everywhere else: a block's frame reaches `blockSpread` past its
                // content either side — see `blockFrame` — and its heading chip stands proud
                // of the top, which a box drawn at the content's own bounds shaved off.
                .padding(.horizontal, Self.blockSpread)
                // Well over the top: the memory's pane reaches exactly `blockSpread` up, and a
                // clip whose rounded corner sat right there shaved its top corners.
                .padding(.top, 40)
                // Rounded, not squared off: what the cut lands on is a card, and a card
                // sliced on a straight line reads as a drawing error rather than a list
                // carrying on past the edge.
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, -Self.blockSpread)
                .padding(.top, -40)
                Spacer(minLength: 0).frame(width: Self.innerGap)
            }
            // A wall for layout: a geometry reader's own size never depends on what is in it,
            // which keeps a grid re-laid at each frame of a fold from re-running the board
            // around it. Measured: half the main thread's work per frame, 0.83 ms to 0.45.
            GeometryReader { _ in
                fleet(scrolling: scrolling)
                    .frame(width: centerWidth, height: Self.blockHeight, alignment: .top)
            }
                .frame(width: centerWidth, height: Self.blockHeight)
                // What is broken rides over the fleet, centred, and only when something is —
                // see `AlertsBlock`. Hung over the top edge rather than stacked on it: in the
                // stack it pushed the whole fleet down the axis the day something broke, and a
                // grid that moves is a grid you have to find again. The panel leaves 126pt of
                // room above this line, so the bar has somewhere to hang.
                .overlay(alignment: .top) {
                    if !AlertsBlock.alerts(controller.hub, crons: controller.launchd.jobs).isEmpty {
                        AlertsBlock(hub: controller.hub, fixer: controller.fixer,
                                    crons: controller.launchd.jobs)
                            // As wide as the fleet's frame: the bar's pane reaches 13pt past
                            // its content either side.
                            .frame(width: fleetFrameWidth - 26)
                            // A heading line and a block's gap over the fleet.
                            .offset(y: -Self.overLine)
                    }
                }
            if controller.hub.isConfigured {
                Spacer(minLength: 0).frame(width: Self.innerGap)
                // The agent block takes what its cards need and no more, half the column at
                // the most; the list has the rest. Five agents under a block sized for fifteen
                // was a third of the column of blue paper.
                //
                // No podium here: it starts on the fleet's own line. It is the other list
                // you are answerable to, and a step below the sessions read as a footnote to
                // them.
                GeometryReader { space in
                    let free = space.size.height - Self.blockGap
                    VStack(alignment: .leading, spacing: Self.blockGap) {
                        CronColumn(title: "CRONS", jobs: controller.launchd.jobs,
                                   commandHeld: controller.commandHeld,
                                   scrolling: !eagerLayout, limit: max(0, free / 2))
                        MoneyColumn(store: controller.money,
                                    scrolling: !eagerLayout, limit: max(0, free * 3 / 4))
                        PluginColumns(store: controller.plugins,
                                      commandHeld: controller.commandHeld,
                                      scrolling: !eagerLayout, limit: max(0, free * 3 / 4))
                        TodoColumn(hub: controller.hub,
                                   commandHeld: controller.commandHeld,
                                   onDismiss: controller.dismiss,
                                   scrolling: !eagerLayout)
                            .frame(maxHeight: controller.hub.todoEmpty ? nil : .infinity)
                    }
                    .animation(Self.fold, value: controller.hub.todoEmpty)
                    .animation(Self.fold, value: controller.launchd.jobs.isEmpty)
                    // Pinned to the top of the column. The agent block takes only what its
                    // cards need, so the stack is shorter than the space it is given — and a
                    // stack left to sit in the middle of that space starts the agents below
                    // the fleet's own line.
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                    // The same height as the column on the other side, so the two lists you
                    // are answerable to end on the same line at the foot of the panel.
                    .frame(width: sideWidth, height: Self.blockHeight, alignment: .top)
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
        // Tighter tracking than the side headings, which are one short word each: at theirs
        // this one runs into the key beside it.
        Block(title: "CLAUDE CODE FLEET", tracking: 2.6, tint: BlockTint.fleet,
              fill: .black.opacity(0.71), spread: Self.fleetSpread, bottomSpread: 13,
              // The grid brings 18pt of glow room over its first row and the frame starts 13pt
              // over the block: five back leaves the tiles their 26pt under the line too.
              titleInset: Self.fleetSpread, titleOnLine: true, bodyGap: -5) {
            legendKey
        } trailing: {
            if !controller.sessions.isEmpty {
                Text("\(controller.sessions.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .titleGround(1)
            }
        } content: {
            // The same gap the side columns leave under their own rule, plus the room the
            // top row's hover glow needs — it reaches 16pt up, and the rule is right there.
            if scrolling {
                // Only the tiles scroll. The mail and todo columns either side stayed put
                // while the whole board slid under them, which read as the panel coming apart.
                // No indicator: a bar down the middle of the panel is furniture, and the
                // tiles cut off at the bottom edge say there is more just as well.
                //
                ScrollView(.vertical) {
                    // Real padding at the top rather than a negative inset on the container:
                    // the heading has to clip what scrolls under it, so the glow's room is
                    // taken inside the scroll view instead of over the rule above it.
                    grid.padding(.horizontal, Self.glowRoom)
                        .padding(.top, 18)
                        .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                // The negative padding is the room the hover glow needs. A ScrollView clips
                // to its own bounds, and the grid is exactly as wide as the column, so the
                // outer tiles had their glow — and the edge of the card itself, once scaled —
                // sliced off.
                .padding(.horizontal, -Self.glowRoom)
                // Told how tall it is, rather than left to take the screen. A ScrollView takes
                // every point it is offered, so the block's frame ran off the bottom whatever
                // was in it; `fixedSize` and a cap draw the rows past the cap out in the open;
                // a height measured from inside never comes back, because a preference does
                // not cross a scroll view; and `ViewThatFits` builds the grid twice, which
                // cost 140ms a tick on a fleet of seven. The tiles are a fixed height in a
                // fixed number of columns, so this is arithmetic.
                // The height the block was given — the same one the two columns either side
                // were given, so all three end on the same line. Whatever is past it scrolls.
                .frame(maxHeight: .infinity, alignment: .top)
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
    private var legendKey: some View {
        // On a ground of its own, like everything else on the panel that is a thing rather
        // than a label. Four dots floating on the scrim read as specks; the same four on a
        // card read as a key. Kept as small as the dots allow — it is furniture, not a
        // control, and it sits on a line with a name and a count either side of it.
        HStack(spacing: 9) {
            legend(.ready)
            // Where the spectrum puts it — the key runs green, blue, violet, red, amber,
            // yellow, and teal sits between the first two. A colour parked on the end
            // reads as an afterthought rather than as one of the set.
            legend(GroupTile.tint)
            legend(.awaitingAnswer)
            legend(.delegated)
            legend(.running)
            legend(.apiError)
            legend(.paused)
            // After yellow, the lightest of the set: beside green it did not blend (asked
            // 2026-10-13).
            legend(.fresh)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // White, where every other card on the panel is outlined at 0.07: the key
                // sits on the fleet's own line, and the fleet's line is black now.
                .strokeBorder(.white.opacity(0.75), lineWidth: 1)
        )
    }

    /// The sessions gathered by the directory they are working in, in the order the sessions
    /// themselves already come in — least recently touched first, so the group holding the
    /// session you have left alone longest leads.
    private func groups(of sessions: [Session]) -> [(name: String, sessions: [Session])] {
        var order: [String] = []
        var byDir: [String: [Session]] = [:]
        for session in sessions {
            let key = session.groupKey
            if byDir[key] == nil { order.append(key) }
            byDir[key, default: []].append(session)
        }
        return order.map { ($0, byDir[$0] ?? []) }
    }

    /// Every directory, and every session that has one to itself.
    private var cells: [FleetCell] {
        groups(of: controller.sessions).compactMap { group -> FleetCell? in
            // A directory holding one session has nothing to gather: its card is the session.
            if group.sessions.count == 1, let only = group.sessions.first {
                return .session(only, heading: only.label ?? only.topic)
            }
            return .group(group.name, group.sessions)
        }
    }


    /// Every card, in rows of three, laid out by hand rather than by stacks — see `FleetLayout`.
    private var grid: some View {
        let cells = self.cells
        // Every directory stands unfolded in the grid itself, its sessions in view with nothing
        // to click (asked 2026-10-12; never folded since 2026-10-18), in one column (asked
        // 2026-10-22).
        let layout = FleetLayout(tile: CGSize(width: tileWidth, height: SessionTile.height),
                                 spacing: tileSpacing, columns: Self.tilesPerRow,
                                 wide: cells.map {
                                     $0.count > 1 ? GroupTile.size(holding: $0.count, in: centerWidth, spacing: tileSpacing) : nil
                                 })
        return layout {
            ForEach(cells) { cell in
                switch cell {
                case let .group(name, sessions):
                    GroupTile(name: name, sessions: sessions,
                              spacing: tileSpacing, width: centerWidth,
                              onActivate: { controller.activate($0) })
                case let .session(session, heading):
                    SessionTile(session: session, heading: heading) {
                        controller.activate(session)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dismissLayer)
    }

    /// Five dots, and no words.
    ///
    /// The words were there to teach the colours and they had stopped teaching anybody
    /// anything — the tiles carry them, spelled out, on every pill. What is left is the palette
    /// itself, which is worth having on the heading for a different reason: it says how many
    /// states there are, so a colour you have not seen this week still reads as one of a set
    /// rather than as something new.
    private func legend(_ state: SessionState) -> some View { legend(state.tint) }

    private func legend(_ tint: Color) -> some View {
        Circle()
            .fill(tint)
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

/// The fleet's grid, placed by hand: three columns of a fixed card, and each directory the
/// cells its sessions take.
struct FleetLayout: Layout {
    /// A session's card.
    var tile: CGSize
    var spacing: CGFloat
    var columns: Int
    /// What each card takes when it is a directory, nil for a session.
    var wide: [CGSize?] = []

    private var width: CGFloat { tile.width * CGFloat(columns) + spacing * CGFloat(columns - 1) }

    private func rows(_ count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return max(0, CGFloat(rows) * tile.height + CGFloat(max(0, rows - 1)) * spacing)
    }

    /// Where every card sits, from the grid's own corner, and how tall that is. Directories lead, one to a row: one met halfway down would leave
    /// the card before it alone on its row. The grid's columns one leaves free beside it take
    /// the next sessions (asked 2026-10-15), as many rows of them as its height holds. A
    /// directory one column wide stands in such a column first, and the sessions take the
    /// cells left round it, under the shorter one included (asked 2026-10-15).
    func rest(_ count: Int) -> (frames: [CGRect], height: CGFloat) {
        var frames = Array(repeating: CGRect.zero, count: count)
        var queue = (0 ..< count).filter { $0 >= wide.count || wide[$0] == nil }[...]
        let step = CGSize(width: tile.width + spacing, height: tile.height + spacing)
        let cells = { (height: CGFloat) in max(1, Int((height + spacing) / step.height)) }
        let unfolded = (0 ..< min(count, wide.count)).filter { wide[$0] != nil }
        // The one with the most rows on the left (asked 2026-10-22); two of a height keep the
        // order they come in, or they would trade places once a second.
        let narrow = unfolded.filter { taken(wide[$0]!.width) == 1 }
            .sorted { (wide[$1]!.height, $0) < (wide[$0]!.height, $1) }
        var placed = Set<Int>()
        var y: CGFloat = 0
        for i in unfolded.filter({ !narrow.contains($0) }) + narrow where !placed.contains(i) {
            placed.insert(i)
            let size = wide[i]!
            frames[i] = CGRect(origin: CGPoint(x: 0, y: y), size: size)
            let taken = min(columns, taken(size.width))
            var depth = (0 ..< columns).map { $0 < taken ? cells(size.height) : 0 }
            var bottom = size.height
            for (column, j) in zip(taken ..< columns, narrow.filter { !placed.contains($0) }) {
                placed.insert(j)
                frames[j] = CGRect(origin: CGPoint(x: CGFloat(column) * step.width, y: y), size: wide[j]!)
                depth[column] = cells(wide[j]!.height)
                bottom = max(bottom, wide[j]!.height)
            }
            // From the top right corner down (asked 2026-10-15), not dropped to its foot: in the
            // columns right of every directory first, under a shorter one after (asked 2026-10-16).
            let slots = (0 ..< depth.max()!).flatMap { row in
                (0 ..< columns).filter { row >= depth[$0] }.map { (row: row, column: $0) }
            }
            let free = slots.filter { depth[$0.column] == 0 } + slots.filter { depth[$0.column] > 0 }
            var tall: CGFloat = 0
            for slot in free {
                guard let t = queue.popFirst() else { break }
                frames[t] = CGRect(x: CGFloat(slot.column) * step.width, y: y + CGFloat(slot.row) * step.height,
                                   width: tile.width, height: tile.height)
                tall = max(tall, CGFloat(slot.row + 1) * step.height - spacing)
            }
            y += max(bottom, tall) + spacing
        }
        // A last row short of the grid's width starts at its left (asked 2026-10-16), not under
        // the column the sessions beside a directory stack in.
        for (n, i) in queue.enumerated() {
            frames[i] = CGRect(x: CGFloat(n % columns) * step.width,
                               y: y + CGFloat(n / columns) * step.height,
                               width: tile.width, height: tile.height)
        }
        return (frames, queue.isEmpty ? max(0, y - spacing) : y + rows(queue.count))
    }

    /// How many of the grid's columns a card this wide covers.
    private func taken(_ width: CGFloat) -> Int {
        Int(((width + spacing) / (tile.width + spacing) - 0.01).rounded(.up))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width, height: rest(subviews.count).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let frames = rest(subviews.count).frames
        for (i, subview) in subviews.enumerated() {
            let frame = frames[i].offsetBy(dx: bounds.minX, dy: bounds.minY)
            subview.place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// What the grid holds: a directory, or one of its sessions.
enum FleetCell: Identifiable {
    case group(String, [Session])
    case session(Session, heading: String?)

    /// How many sessions the card stands for.
    var count: Int {
        if case let .group(_, sessions) = self { return sessions.count }
        return 1
    }

    var id: String {
        switch self {
        case let .group(name, _): return "dir:" + name
        case let .session(session, _): return "pid:\(session.id)"
        }
    }
}

/// One working directory, its sessions as cards inside its own border, in the one colour no
/// state wears: one of the grid's columns, a cell down for each of its sessions (asked
/// 2026-10-22: two side by side in one row were left half a card's height under the name).
struct GroupTile: View {
    let name: String
    let sessions: [Session]
    var spacing: CGFloat
    /// The grid's width, which its cards are laid out at.
    var width: CGFloat
    let onActivate: (Session) -> Void

    /// The group colour. Teal because every other hue on the panel is spoken for by a state —
    /// green ready, red working, blue asking, amber failing, purple delegated, yellow held —
    /// and a card that borrowed one of those would read as a session in that state.
    static let tint = Color(red: 0.16, green: 0.82, blue: 0.80)

    /// What the card takes: one of the grid's cells across, and as many down as it holds.
    static func size(holding count: Int, in width: CGFloat, spacing: CGFloat) -> CGSize {
        let cell = cell(width, spacing: spacing)
        return CGSize(width: cell.width, height: CGFloat(count) * (cell.height + spacing) - spacing)
    }
    /// One cell of the grid a block this wide holds.
    static func cell(_ width: CGFloat, spacing: CGFloat) -> CGSize {
        let across = CGFloat(OverlayView.tilesPerRow)
        let cell = (width + spacing) / across - spacing
        return CGSize(width: cell, height: SessionTile.height(width: cell))
    }
    /// Between the group's border and its cards, across and down, and between two of its
    /// cards: the one gap (asked 2026-10-15).
    static let inset: CGFloat = 10
    /// The name, and the room it keeps over and under it: more under it than over it, where
    /// the border already is (asked 2026-10-15).
    private static let nameSize: CGFloat = 20
    private static let nameLine = nameSize * 1.2
    private static let nameAir: CGFloat = 4
    private static let nameFoot: CGFloat = 11
    /// The name stands centred over the cards, in a band of its own.
    static let nameBand = nameAir + nameLine + nameFoot
    /// One of its cards: the group's cells less the gaps and the name's band.
    static func card(count: Int, in width: CGFloat, spacing: CGFloat) -> CGSize {
        let outer = size(holding: count, in: width, spacing: spacing)
        let rows = CGFloat(count)
        return CGSize(width: outer.width - 2 * inset,
                      height: (outer.height - (rows + 1) * inset - nameBand) / rows)
    }

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .topLeading) {
                Cards(sessions: sessions, spacing: spacing, width: width, onActivate: onActivate)
                    // Held to the card's own size as far as the stack goes: left to their
                    // full one, they ran out past the border.
                    .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)

                Text(name)
                    .font(.system(size: Self.nameSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: (box.size.width - nameWidth) / 2, y: Self.inset + Self.nameAir)
            }
            // The empty room inside the card belongs to the directory: a click there does not
            // fall through to the panel's dismiss layer. The cards inside take their own clicks.
            .contentShape(Rectangle())
            .onTapGesture {}
        }
        // Nothing leaves the border, not even a card's hover glow.
        // Round its cards, as round as theirs plus the room between.
        .clipShape(RoundedRectangle(cornerRadius: 10 + Self.inset, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10 + Self.inset, style: .continuous)
                // No glow at all: a group has had nothing to click since 2026-10-18, and its
                // glow still read as a shadow behind it while one of its cards was hovered.
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10 + Self.inset, style: .continuous)
                .strokeBorder(Self.tint, lineWidth: 2.5)
        )
    }

    /// The name's width at rest, measured rather than laid out: the text is placed by hand, so
    /// centring it needs a number before anything is drawn.
    private var nameWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.nameSize, weight: .semibold)
        return (name as NSString).size(withAttributes: [.font: font]).width
    }

    /// The sessions, under the name, in the order the grid has them.
    private struct Cards: View {
        let sessions: [Session]
        let spacing: CGFloat
        let width: CGFloat
        let onActivate: (Session) -> Void

        var body: some View {
            let card = GroupTile.card(count: sessions.count, in: width, spacing: spacing)
            VStack(alignment: .leading, spacing: GroupTile.inset) {
                ForEach(sessions, id: \.id) { session in
                    // Inside a directory the card wears its topic: the directory is
                    // what these sessions have in common, and a row of cards all
                    // saying "portfolio" is a row you cannot choose from.
                    SessionTile(session: session, heading: session.label ?? session.topic,
                                grouped: true) {
                        onActivate(session)
                    }
                    .frame(width: card.width, height: card.height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Clear of the name, which is drawn over this rather than above it — and clear by
            // a margin: a row of cards starting five points under the title read as its
            // underline.
            .padding(.top, GroupTile.inset + GroupTile.nameBand)
            .padding([.horizontal, .bottom], GroupTile.inset)
            .frame(width: width, alignment: .top)
        }
    }
}

/// One session, read at a glance: the name and the state border. Everything else is a
/// distraction at this size; `--scan` is there when you want the details.
struct SessionTile: View {
    let session: Session
    /// What the card is called, when the directory name it defaults to would say nothing —
    /// inside a group, where every card shares that directory.
    var heading: String?
    /// Inside a group, whose heading already names the directory: no folder in the
    /// corner, which leaves the pills the whole line.
    var grouped = false
    let onSelect: () -> Void

    /// Sub-agent work gets its own colour rather than the state tint, and it is the same purple
    /// the border wears when the agents are the only thing running: one colour, one meaning —
    /// work happening on a thread that is not the one you would be talking to.
    static let subagentTint = SessionState.delegated.tint

    @State private var hovering = false

    /// What three take beside the side columns on a 1470 pt laptop screen, with some edge left.
    static let width: CGFloat = 212
    /// Every session card is 16:9 (asked 2026-10-15), on the grid and inside a group.
    static let height = width * 9 / 16
    static func height(width: CGFloat) -> CGFloat { width * 9 / 16 }

    private func ground(_ shape: some Shape) -> some View {
        shape
            .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
            // A shadow fades out about twice its radius away. At 16 the hover glow ran past the
            // room it is given, and was cut in a straight line: by the scroll view over the top
            // row, by a group's border, and over the card beside it in a group (2026-10-20).
            // The pointer no longer brightens it at all (asked the same day).
            .shadow(color: session.state.tint.opacity(0.18), radius: grouped ? 4 : 8)
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .top) {
                // The name alone, in the middle of the card, and no line of what it last ran or
                // is running — inside a group since 2026-10-12, on the grid since 2026-10-15:
                // the border and the pill say its state.
                name
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Pills side by side while the two of them fit the tile, stacked in the corner
                // when they don't — never shrunk: every pill is the same size on every tile. A
                // long workflow pill beside a sub-agent count used to shrink one and break the
                // other over two lines, and eat the folder name.
                HStack(alignment: .top, spacing: 5) {
                    // The folder gives way, down to nothing: the fit used to count it and a
                    // 16 pt gap, and "~" beside two pills stacked them for half a point (02-10).
                    if !grouped { folder.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading) }
                    // Served first and at full size: the folder's 110pt cap squeezed the pills
                    // — BACKGROUND-TASK shrunk to 70%, then cut to "BACKGROU…SK" (28-09).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) { subagentPill; statePill }.fixedSize()
                        // A 16:9 card has one line of pills to give: stacked, the second sat
                        // on the name.
                        statePill
                    }
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(11)
            }
            // Inside a group, the height its row gives it — see `GroupTile.Cards`.
            .frame(height: grouped ? nil : Self.height, alignment: .top)
            // The glow is cast by the card's own ground, a single shape, rather than by the
            // card as a group: a shadow taken from a group of layers is an offscreen pass per
            // tile on every frame anything on the panel moves — a todo column scrolling included.
            .background { ground(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
            .overlay {
                // Thinner inside a group (asked 2026-10-15), whose own border is round them.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(session.state.tint, lineWidth: grouped ? 2.5 * 0.75 : 2.5)
            }
            .scaleEffect(hovering ? 1.015 : 1.0)
            // Without this the card snaps to its hovered size in one frame, which reads as a
            // flicker rather than as a response to the pointer.
            .animation(.easeOut(duration: 0.18), value: hovering)
            // A turn ending is a colour change on four surfaces at once — border, glow, pill
            // and whichever movement the edge was carrying. Crossfaded rather than cut, and
            // short enough that a session which finishes and is prompted again mid-fade turns
            // around on the spot instead of finishing a transition that is already wrong.
            .animation(.easeInOut(duration: 0.22), value: session.state)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var name: some View {
        // A topic is a sentence where a directory is a word, so it is set smaller and given a
        // second line rather than shrunk to a third of the size to fit on one.
        Text(heading ?? session.displayName)
            // Smaller on 2026-10-15: 0.9 of what it was, then on the grid 0.75 of that; on a
            // group's smaller cards bigger again the same day.
            .font(.system(size: grouped ? 16 : (heading == nil ? 31 : 22) * 0.9 * 0.75,
                          weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(heading == nil ? 1 : 2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var folder: some View {
        Text(session.folder)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
            .truncationMode(.tail)
            // Capped so a long path outside ~/self truncates instead of stacking the pills.
            .frame(maxWidth: 110, alignment: .leading)
    }

    /// Sits next to the state pill while sub-agents are out. The pill says the session is
    /// working; this says who is actually doing the work.
    @ViewBuilder private var subagentPill: some View {
        let running = session.subagents.count
        if running > 0, session.workflow == nil {
            Text("SUB-AGENTS: \(running)")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .lineLimit(1)
                .foregroundStyle(Self.subagentTint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Self.subagentTint.opacity(0.14), in: Capsule())
        }
    }

    private var statePill: some View {
        // A workflow's progress rides in the pill that says the session is waiting on it.
        let label = session.state.label
        let text = session.workflow.map { Text("\(label): \($0.pill())") }
            ?? session.delegatedSince.map {
                let age = WorkflowProgress.duration(Date().timeIntervalSince($0))
                // Under any state but its own the shell is named, in its colour: a bare
                // "WORKING · 28m in" read as a turn 28 minutes long (asked 2026-10-13). And no
                // "in" after the age: with it, a group's card cut the label from an hour on.
                return session.state == .delegated
                    ? Text("\(label) · \(age)")
                    : Text("\(label) · ") + Text("BG-TASK \(age)").foregroundStyle(Self.subagentTint)
            }
            ?? Text(label)
        return text
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            // Never broken over two lines: "BACKGROUN / D" beside a sub-agent pill is what a
            // header short of room did to it. Never shrunk either (asked 2026-09-28): a
            // workflow's progress too long even alone on its line is cut, not scaled.
            .lineLimit(1)
            .truncationMode(.middle)
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
    /// The processes holding the memory are listed only while ⌘ is down, like the todo column's
    /// controls: each carries a ✕, and a list of kill buttons is not something to leave lying
    /// on a panel you glance at.
    let commandHeld: Bool
    /// And only while the pointer is on the block: ⌘ is held for the fleet, the todos, the
    /// agents too, and a list of kill buttons unfolding in the corner every time reads as
    /// the panel changing under your hands.
    @State private var hovered = CommandLine.arguments.contains("--strain")
    /// Drives the warning's pulse; flipped once on appear, the animation repeats by itself.
    @State private var flash = false
    private var amber: Color { Color(red: 1.00, green: 0.62, blue: 0.15) }

    var body: some View {
        let tight = reaper.struggling && !reaper.hogs.isEmpty
        let tint = tight ? amber : Color.white
        // "One line at rest" was written and never enforced: with nothing to put under the
        // heading the frame still ran 13pt past it, so an idle machine got a bar of empty
        // amber with a chip sitting on it. A block with nothing to say is the heading alone.
        // Swap is never shown: asked on 2026-09-27.
        let hasBody = tight && commandHeld && hovered

        // The one block that is a reading rather than a list, so the only one drawn as a
        // gauge: a dark pane filled from the left to your apps' share of the RAM macOS leaves you. Every other
        // block is a flat tint because every other block is a count of things; this is a level.
        return Block(title: "MEMORY",
                     titleColor: tight ? tint : .white.opacity(0.92),
                     tint: ramTint.opacity(0.45),
                     fill: .black.opacity(0.41),
                     level: BlockLevel(share: reaper.footprint.ownShare, tint: ramTint.opacity(0.42)),
                     // 10pt of pane between the chips' ground and the first process, as round
                     // the chips: at 6 the list sat 3pt under them (asked 2026-09-28).
                     bodyGap: 13, middleBetween: true) {
            // Under strain the verdict is a pulsing triangle halfway between the name and the
            // readout: a sentence under the heading said nothing the colour did not.
            if tight {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(amber)
                    .opacity(flash ? 1 : 0.2)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: flash)
                    .onAppear { flash = true }
            }
        } trailing: {
            // The whole readout, where every other block puts its count. The share in the
            // block's own colour — the same verdict the frame is painted in, said twice on
            // the one line where it can be read as a figure.
            (Text("RAM \u{00B7} ").foregroundColor(.white.opacity(0.9))
                + Text(percentLabel).foregroundColor(ramTint)
                + Text(" \u{00B7} \(byteLabel(reaper.footprint.room))").foregroundColor(.white.opacity(0.9)))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .titleGround()
        } content: {
            // Left out rather than left empty: a row of no height still takes the stack's
            // spacing, which is water under the words and none over them.
            if hasBody {
            // The processes holding the memory, which is the only thing to do about it. One
            // after the other, each easing down out of the bar, so the eye follows the list as
            // it forms. Gone at once when ⌘ comes up: there is nothing to watch on the way out.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(reaper.hogs.enumerated()), id: \.element.id) { index, hog in
                    HogPill(hog: hog, tint: amber)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -8))
                                .animation(.easeOut(duration: 0.4).delay(Double(index) * 0.09)),
                            removal: .opacity.animation(.easeIn(duration: 0.12))))
                }
            }
            .padding(.horizontal, 4)
            }
        }
        .onHover { hovered = $0 }
    }

    /// What colour the block is: your apps' share of the RAM, on the scale the figure itself
    /// used to be drawn in — and red outright once Fleet is holding sessions back, whatever
    /// the share says.
    private var ramTint: Color {
        if reaper.struggling { return SessionState.running.tint }
        return Self.scale(reaper.footprint.ownShare, 0.60, 0.75, 0.88) ?? BlockTint.memory
    }

    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    /// Why the block is amber, in the few words the heading has room for. The long version of
    /// the same sentence is what the sessions are told — see `Hooks.machinePath`.

    /// How full your part of the RAM is — the figure itself, since the gigabytes behind it say less at a
    /// glance than the share does.
    private var percentLabel: String { percent(reaper.footprint.ownShare) }

    /// A share on the panel's own four colours: green while there is room, then the blue and
    /// the amber the tiles use for "someone is waiting", then the red they use for trouble.
    ///
    /// The thresholds are this app's, not Apple's — Apple publishes no number for any of these.
    /// The one verdict it does publish is the pressure level, and that is already what turns
    /// this whole block amber. These three only say which of the four is filling up first.
    ///
    /// Steps rather than a gradient: a colour you can name is a colour you can read out of the
    /// corner of your eye, and a continuous ramp is neither.
    /// The RAM's own colour, for anything outside this view that wants the same verdict —
    /// the menu bar dot, which is the one place Fleet shows while the panel is down.
    static func loadTint(_ ram: MemoryPressure.Footprint) -> Color {
        guard ram.total > 0 else { return SessionState.ready.tint }
        return scale(Double(ram.used) / Double(ram.total), 0.60, 0.75, 0.88)
            ?? SessionState.ready.tint
    }

    private static func scale(_ share: Double, _ ok: Double, _ watch: Double,
                              _ bad: Double) -> Color? {
        switch share {
        case 0: return nil                      // grey: nothing there to have an opinion about
        case ..<ok: return SessionState.ready.tint
        case ..<watch: return SessionState.awaitingAnswer.tint
        case ..<bad: return SessionState.apiError.tint
        default: return SessionState.running.tint
        }
    }
}

extension Color {
    /// The same hue with the light taken out of it, and no transparency: `opacity` on a panel
    /// that floats over your windows lets them through, which reads as a colour gone grey.
    func darkened(_ amount: Double) -> Color {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let keep = max(0, 1 - amount)
        return Color(red: Double(rgb.redComponent) * keep,
                     green: Double(rgb.greenComponent) * keep,
                     blue: Double(rgb.blueComponent) * keep)
    }

    /// The same hue pulled towards white. A label in the tint over a block already filled with
    /// that tint sits at 2.5:1; mixing it with white keeps the hue and clears 4.5:1.
    func lightened(_ amount: Double) -> Color {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let mix = min(1, max(0, amount))
        return Color(red: Double(rgb.redComponent) * (1 - mix) + mix,
                     green: Double(rgb.greenComponent) * (1 - mix) + mix,
                     blue: Double(rgb.blueComponent) * (1 - mix) + mix)
    }
}

extension View {
    /// The frame around a whole block — a frosted glass in the block's own colour, outlined in
    /// it — with the heading inside it
    /// like MEMORY's: 13pt of pane over the name, as on the other three sides. It used to run
    /// through the middle of the heading line, broken by the chips; asked on 2026-09-27 to take
    /// the names in, like MEMORY and REELS.
    ///
    /// Drawn outside the block's own bounds rather than padded into them, so hanging a frame on
    /// a column moves nothing inside it: the cards keep the width they had.
    /// `bottomSpread` is for the blocks that keep room at the bottom inside them: the fleet leaves
    /// 20pt under its last row for the hover glow. Without it those 20pt add to the spread, and
    /// the black reaches twice as far below as on the sides.
    func blockFrame(_ tint: Color, fill: Color? = nil, spread: CGFloat = 13,
                    bottomSpread: CGFloat? = nil, topSpread: CGFloat = 13,
                    level: BlockLevel? = nil) -> some View {
        background(alignment: .top) {
            // Circular, as the glass's own mask is, so the two corners meet.
            let corner = RoundedRectangle(cornerRadius: Glass.radius)
            corner
                // The same colour as the line, laid over the block's frosted glass. A block is
                // tinted, not coloured: the cards inside are opaque and keep their own
                // near-black, so this only ever shows in the margins. Darkened rather than
                // thinned: the hue is taken down towards black first, so it stays its own
                // colour. Thin enough that the blur behind it still shows.
                .fill((fill ?? tint.darkened(0.48)).opacity(Glass.wash))
                .overlay(alignment: .leading) {
                    if let level {
                        GeometryReader { box in
                            level.tint
                                .frame(width: box.size.width * level.share)
                                // Named here rather than inherited, so the refusal below keeps
                                // the gauge from being drawn in on open and this still carries
                                // it from one reading to the next: a gauge that jumps is read
                                // as a glitch, one that slides as a level.
                                .animation(.easeOut(duration: 0.5), value: level.share)
                        }
                    }
                }
                .background { FrostedGlass() }
                .clipShape(corner)
                .overlay(corner.strokeBorder(tint, lineWidth: 1))
                // A gauge inherits whatever animation is in flight when the panel opens, and
                // one being animated in is one you watch fill up. It is a reading: it is right
                // the instant it is on screen. Other blocks keep theirs, to fold smoothly.
                .transaction { if level != nil { $0.animation = nil } }
                .padding(.top, -topSpread)
                .padding(.horizontal, -spread)
                .padding(.bottom, -(bottomSpread ?? spread))
        }
    }

    /// Grey and half there, whatever the block: the colour is the block's own background now,
    /// and a chip in that same colour laid on top of it was a second statement of it. What a
    /// chip has to do is break the outline and stay readable, which a wash and an edge do.
    /// `ground` thins the near-black behind the words. Every chip sits *in* its block now, and
    /// a solid one is a hole punched in the block's colour: letting some of it through is what
    /// says the chip is in it.
    func titleGround(_ ground: Double = 0.55) -> some View {
        padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                // Opaque first, wash second. The block's own colour starts at this line, and a
                // translucent chip let it through — the name sat on a coloured smear instead of
                // on the panel. The near-black is the one every card on the panel is drawn on.
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(ground))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.12 * ground)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1)))
            .padding(.horizontal, -7)
            .padding(.vertical, -3)
    }
}

/// A colour per block, worn on the heading's own chip and nowhere else.
///
/// Dark enough that the name stays white on top of it: these are labels on the quietest panel
/// on the machine, and a block that announces itself in full-strength yellow would outshout the
/// only thing here that uses colour to mean something — a session's state.
enum BlockTint {
    static let mail = Color(red: 0.40, green: 0.32, blue: 0.05)
    /// Deeper and more violet than the todo column's steel blue, and as light: the outline is
    /// drawn in the tint itself, and at the old navy the block had no visible edge at all.
    static let epitech = Color(red: 0.18, green: 0.24, blue: 0.62)
    /// Grey, like SOCIAL MEDIA: these two blocks state, they ask for nothing. Only the RAM gauge
    /// keeps a colour, and it takes it from its own rate.
    static let memory = Color(white: 0.24)
    /// Grey, the outline alone: the fill stays black (see `fleet`), because the fleet is the
    /// only block whose contents already carry colour — six session states, on every tile. The
    /// outline is drawn in the tint like every other block's, light enough to be seen.
    static let fleet = Color(white: 0.5)
    static let todo = Color(red: 0.13, green: 0.28, blue: 0.52)
    /// SPENDING's green, asked for by name. Deep, so the kinds' own colours stay the brightest
    /// thing in the block.
    static let money = Color(red: 0.10, green: 0.40, blue: 0.22)
    /// The two networks' own colours, dimmed to the panel's level: Instagram's pink and
    /// YouTube's red. Quiet, because neither block has anything to say most days — but their
    /// own, because a block is told apart by its colour everywhere else on this panel.
    static let reels = Color(red: 0.47, green: 0.12, blue: 0.31)
    static let youtube = Color(red: 0.47, green: 0.09, blue: 0.09)
}

private struct HogPill: View {
    let hog: Hog
    let tint: Color
    @State private var hovering = false

    /// What the line ends on — the ✕ and the word "auto" are given the same width so both
    /// stop on the same edge.
    private static let button: CGFloat = 30

    /// The text's own inset inside the capsule. Public because the sentence above the list
    /// lines up on it.
    static let inset: CGFloat = 10

    var body: some View {
        // Three columns, not a sentence: the name, then the size and the button pushed to the
        // right edge. Laid out one after the other they landed at a different point on every
        // line — four processes, four places to look for the ✕.
        HStack(spacing: 8) {
            Text(hog.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(hog.sizeLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))

            if hog.reapable {
                // Already condemned: saying so is more useful than offering a ✕ for something
                // that is about to go by itself.
                Text("auto")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                    .fixedSize()
                    .frame(width: Self.button, alignment: .trailing)
            } else {
                Button { Reaper.dismiss(pid: hog.pid) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.35))
                        // The one width both endings share, so the ✕ of one line and the
                        // "auto" of the next end on the same edge.
                        .frame(width: Self.button, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
        }
        // Its own capsule: side by side on one amber line, four processes read as one string
        // of words. The border is what says where one ends and the next begins.
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule().fill(.white.opacity(0.06))
                .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
        )
    }
}
