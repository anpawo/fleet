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


    /// How tall the grid's own area is, measured rather than worked out: the heading above it
    /// is laid out, not arithmetic, and an open directory has to end exactly where the two
    /// columns either side of it do.
    @State private var gridSpace: CGFloat = 0

    /// EPITECH open under the pointer — see `EpitechColumn.open`. Seeded from `--school-open`
    /// so a render can show it.
    @State private var schoolOpen = CommandLine.arguments.contains("--school-open")

    /// Which directory is unfolded. On the controller, not here: Esc and the panel chord fold
    /// it as they dismiss, and a piece of `@State` is not something they can reach. It is
    /// also rebuilt-proof — every row is rebuilt each tick, so a fold kept on a row would snap
    /// shut once a second.
    /// The open directory — but only while it still *is* a directory. A group that drops to
    /// one session becomes a plain card, and an `openGroup` still naming it matched nothing:
    /// every card in the block went to opacity 0 and the block sat blank until Esc.
    private var openGroup: String? {
        guard let name = controller.openGroup,
              cells.contains(where: { $0.id == "dir:" + name }) else { return nil }
        return name
    }

    /// What the grid takes off that height — its own padding, top and bottom.
    private static let gridPadding: CGFloat = 38

    /// Opening a directory moves every other card at once. Cut rather than animated, the grid
    /// reads as a different grid each click.
    static let unfoldDuration = 0.28
    private static let unfold = Animation.easeOut(duration: unfoldDuration)


    /// Fixed tiles per row and fixed width, rather than adaptive: a partial last row, and a
    /// one-session fleet, start at the same left edge as every full row rather than drifting
    /// to the middle. A lone tile that centres itself reads as a different column each time
    /// the fleet is odd-numbered.
    ///
    /// Three (asked 2026-10-15), on tiles narrow enough that the side columns keep their width.
    private static let tilesPerRow = 3
    /// How dark the panel sits over your desktop. Lower shows more of what's behind it.
    private static let tintOpacity: Double = 0.80

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
                // line: EPITECH under the pointer, MAIL the rest of the time, REELS the day the
                // inbox is empty (asked 2026-10-15). The others are their heading, or as tall
                // as what they hold. Each scrolls inside its share, so none can push another
                // off the bottom.
                let hub = controller.hub
                let school = schoolOpen && !hub.schoolEmpty
                let reelsRoom = hub.mailEmpty && !school
                VStack(alignment: .leading, spacing: Self.blockGap) {
                    MemoryStrip(reaper: controller.reaper,
                                commandHeld: controller.commandHeld)
                    ReelBlock(hub: hub, commandHeld: controller.commandHeld,
                              limit: Self.columnHeight / 3, expanded: reelsRoom)
                    GeometryReader { space in
                        let free = space.size.height - Self.blockGap
                        VStack(alignment: .leading, spacing: Self.blockGap) {
                            // Under an open school, three sevenths at most. Otherwise all of it
                            // but EPITECH's heading line and the gap over it — a limit counts
                            // the frame, which reaches `blockSpread` past the block top and
                            // bottom.
                            MailColumn(hub: hub,
                                       commandHeld: controller.commandHeld,
                                       scrolling: !eagerLayout,
                                       limit: school ? max(0, free * 3 / 7)
                                           : space.size.height - Self.overLine + 2 * Self.blockSpread)
                            EpitechColumn(hub: hub,
                                          commandHeld: controller.commandHeld,
                                          onDismiss: controller.dismiss,
                                          scrolling: !eagerLayout,
                                          open: $schoolOpen)
                                .frame(maxHeight: school ? .infinity : nil, alignment: .top)
                        }
                        .frame(height: space.size.height, alignment: .top)
                    }
                    // Two heading lines and the gap between them while REELS has the room:
                    // held, so that the list over them is the one block left to grow.
                    .frame(height: reelsRoom ? Self.overLine + 14 : nil)
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
                .background(GeometryReader { room in
                    Color.clear
                        .onAppear { gridSpace = room.size.height }
                        .onChange(of: room.size.height) { _, height in gridSpace = height }
                })
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

    /// What is left in the grid once a directory is open: every *other* directory, and every
    /// session that has one to itself. An open directory's sessions are drawn inside it, and
    /// these are pushed off the bottom of the block by its height.
    private var cells: [FleetCell] {
        groups(of: controller.sessions).compactMap { group -> FleetCell? in
            // A directory holding one session has nothing to gather: its card is the session,
            // and one click goes there rather than unfolding a group of one on the way.
            if group.sessions.count == 1, let only = group.sessions.first {
                return .session(only, heading: nil)
            }
            return .group(group.name, group.sessions)
        }
    }

    /// Which card the layout is growing or shrinking, as a place in `cells`. Not the open one:
    /// the *last* one, so a directory being folded back up still has a card to shrink into.
    private var openIndex: Int? {
        guard let name = openGroup ?? controller.lastGroup else { return nil }
        return cells.firstIndex { $0.id == "dir:" + name }
    }

    /// Whether this card is the directory that is open.
    private func isOpen(_ cell: FleetCell) -> Bool {
        guard let name = openGroup else { return false }
        return cell.id == "dir:" + name
    }

    /// How tall the open card can be: the room the grid has. Offscreen nothing has been laid out
    /// to measure, so a fleet's worth of rows stands in.
    private var openHeight: CGFloat {
        gridSpace > 0 ? gridSpace - Self.gridPadding
                      : max(0, Self.blockHeight - Self.gridPadding - 132)
    }

    /// What a directory takes of the block when it has it to itself.
    private func alone(_ count: Int) -> (large: Bool, size: CGSize) {
        GroupTile.alone(holding: count, room: openHeight, in: centerWidth, spacing: tileSpacing)
    }

    /// Every card, in rows of three, laid out by hand rather than by stacks — see `FleetLayout`.
    /// One view per card, whatever is open: the card you click is the card that grows, moving
    /// and resizing from where it sits to the top of the block, and the others are placed off the
    /// bottom edge on the way out. Nested stacks could not do that. A card in one row and a
    /// block at the top are two different places in the view tree, so the first was removed and
    /// the second inserted — the card blinked out of the grid and the block arrived from above.
    private var grid: some View {
        let cells = self.cells
        // A directory that fits stands unfolded in the grid itself: its sessions are in view
        // with nothing to click, and the rest of the fleet is still there under it (asked
        // 2026-10-12). A click does not give it the block, as it does one that did not fit:
        // there is no more of it to show.
        let layout = FleetLayout(tile: CGSize(width: tileWidth, height: SessionTile.height),
                                 spacing: tileSpacing, columns: Self.tilesPerRow,
                                 open: openIndex,
                                 openSize: openIndex.map { alone(cells[$0].count).size } ?? .zero,
                                 openHeight: openHeight,
                                 progress: openGroup == nil ? 0 : 1)
            .unfolding(cells.map(\.count), room: openHeight) {
                GroupTile.size(holding: $0, large: $1, in: centerWidth, spacing: tileSpacing)
            }
        let unfolded = Set(zip(cells, layout.wide).filter { $0.1 != nil }.map(\.0.id))
        // Which directories stand on the larger cards: unfolded in the grid, where the grid
        // had the room; folded, where the block has, since a click gives it the block.
        let large = Set(cells.indices.filter {
            unfolded.contains(cells[$0].id) ? layout.large.contains($0) : alone(cells[$0].count).large
        }.map { cells[$0].id })
        return layout {
            ForEach(cells) { cell in
                Group {
                    switch cell {
                        case let .group(name, sessions):
                        GroupTile(name: name, sessions: sessions,
                                  open: openGroup == name || unfolded.contains(cell.id),
                                  // One that has the block all the same (a fleet of one
                                  // directory comes up so) still folds back.
                                  toggles: openGroup == name || !unfolded.contains(cell.id),
                                  commandHeld: controller.commandHeld,
                                  large: large.contains(cell.id), spacing: tileSpacing,
                                  full: CGSize(width: centerWidth, height: openHeight),
                                  scrolling: !eagerLayout,
                                  onToggle: {
                                      withAnimation(Self.unfold) {
                                          controller.openGroup = openGroup == name ? nil : name
                                      }
                                  },
                                  onActivate: { controller.activate($0) })
                    case let .session(session, heading):
                        SessionTile(session: session, heading: heading) {
                            controller.activate(session)
                        }
                    }
                }
                // Gone, not merely elsewhere: a card leaving the block passes under the one
                // that is growing, and is faded out by the time it reaches the edge. An open
                // directory is the only thing on the block until you fold it.
                .opacity(openGroup == nil || isOpen(cell) ? 1 : 0)
                .zIndex(isOpen(cell) ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Belt as well as braces. The fold is set inside `withAnimation`, but the value lives
        // on the controller: the update reaches the panel through `objectWillChange`, and a
        // transaction that does not survive that trip leaves the layout to jump to its final
        // numbers in one frame — which is the instant swap this whole layout exists to avoid.
        .animation(Self.unfold, value: openGroup)
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

/// The fleet's grid, placed by hand.
///
/// Three columns of a fixed card, and — when a directory is open — that one card grown from the
/// top left to the whole block while every other card is placed past the bottom edge, where
/// the block clips them away.
///
/// Written as a `Layout` rather than as stacks because the opening has to be one card moving: in
/// nested stacks the open card and the folded one are two different places in the view tree, so
/// SwiftUI removes one and inserts the other, and what you see is a card blinking out of the
/// grid and a block arriving from above.
///
/// And `animatableData` is what makes it an opening rather than a cut. A layout without it is
/// re-run once with the new numbers: every card is already at its destination on the first
/// frame, which looks exactly like the removal it replaced. With it, SwiftUI interpolates
/// `progress` and asks for the placements at each step, so the card you clicked grows out of
/// its own slot into the block.
struct FleetLayout: Layout {
    /// A folded card's size, which is every card's size until one is opened.
    var tile: CGSize
    var spacing: CGFloat
    var columns: Int
    /// What each card takes when it is a directory unfolded in the grid, nil for one the
    /// size of a tile — see `unfolding`.
    var wide: [CGSize?] = []
    /// Which of those stand their sessions on the larger cards.
    var large: Set<Int> = []
    /// The card that is opening — or the one that was open and is folding back up. Kept
    /// through the close, since a card that loses its place the moment you click has nothing
    /// to shrink back from.
    var open: Int?
    /// What the open card is given: the room the grid has, all of it.
    var openSize: CGSize
    /// That room, which the other cards leave past.
    var openHeight: CGFloat
    /// One that stood unfolded in the grid stays the size it was: grown onto the larger
    /// cards at the click, every one of its cards was laid out again in that frame.
    private var opened: CGSize { open.flatMap { $0 < wide.count ? wide[$0] : nil } ?? openSize }
    /// 0 folded, 1 open. The one thing that is animated; everything else is arithmetic on it.
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var width: CGFloat { tile.width * CGFloat(columns) + spacing * CGFloat(columns - 1) }

    private func rows(_ count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return max(0, CGFloat(rows) * tile.height + CGFloat(max(0, rows - 1)) * spacing)
    }

    /// Where every card sits while none has the block, from the grid's own corner, and how
    /// tall that is. Unfolded directories lead, one to a row: one met halfway down would leave
    /// the card before it alone on its row. The grid's columns one leaves free beside it take
    /// the next sessions (asked 2026-10-15), as many rows of them as its height holds.
    func rest(_ count: Int) -> (frames: [CGRect], height: CGFloat) {
        var frames = Array(repeating: CGRect.zero, count: count)
        var queue = (0 ..< count).filter { $0 >= wide.count || wide[$0] == nil }[...]
        let step = CGSize(width: tile.width + spacing, height: tile.height + spacing)
        var y: CGFloat = 0
        for i in 0 ..< count where i < wide.count {
            guard let size = wide[i] else { continue }
            frames[i] = CGRect(origin: CGPoint(x: 0, y: y), size: size)
            let taken = taken(size.width)
            let across = max(0, columns - taken)
            let down = max(1, Int((size.height + spacing) / step.height))
            var beside: [Int] = []
            while beside.count < across * down, let t = queue.popFirst() { beside.append(t) }
            let tall = CGFloat((beside.count + across - 1) / max(1, across)) * step.height - spacing
            // Level with the directory's foot, not its top (asked 2026-10-15): the gap under
            // them is the gap under it.
            let drop = max(0, size.height - tall)
            for (slot, t) in beside.enumerated() {
                frames[t] = CGRect(x: CGFloat(taken + slot % across) * step.width,
                                   y: y + drop + CGFloat(slot / across) * step.height,
                                   width: tile.width, height: tile.height)
            }
            y += max(size.height, tall) + spacing
        }
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

    /// This grid with the directories that fit unfolded in it. `sizes` is how many sessions
    /// each card holds, `size` what a directory of so many takes on its smaller cards or its
    /// larger. The one holding the most is tried first, and each stays unfolded only
    /// if the grid still ends inside `room` with it so: one that does not fit leaves the next
    /// its chance, and a grid already past `room` unfolds none. The larger cards come after,
    /// in the same order and on the same condition (asked 2026-10-12): none is folded for
    /// another to stand larger.
    func unfolding(_ sizes: [Int], room: CGFloat, size: (Int, Bool) -> CGSize) -> FleetLayout {
        var layout = self
        layout.wide = Array(repeating: nil, count: sizes.count)
        // Two of a size in the order they come: a tie settled another way at each pass is two
        // directories trading places once a second.
        let order = sizes.indices.filter({ sizes[$0] > 1 }).sorted(by: { (sizes[$1], $0) < (sizes[$0], $1) })
        for large in [false, true] {
            for i in order where !large || layout.wide[i] != nil {
                // Kept on its smaller cards while they leave a column free and a card is there
                // to stand in it (asked 2026-10-15): the larger ones take the whole width.
                if large, let small = layout.wide[i], layout.taken(small.width) < columns,
                   layout.wide.contains(where: { $0 == nil }) { continue }
                let before = layout.wide[i]
                layout.wide[i] = size(sizes[i], large)
                if layout.rest(sizes.count).height > room {
                    layout.wide[i] = before
                } else if large {
                    layout.large.insert(i)
                }
            }
        }
        return layout
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Open, the grid is exactly the open card: the others are off the bottom, and counting
        // them would give the scroll view somewhere to scroll them back into view.
        let folded = rest(subviews.count).height
        return CGSize(width: width, height: folded + (opened.height - folded) * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let frames = rest(subviews.count).frames.map { $0.offsetBy(dx: bounds.minX, dy: bounds.minY) }
        for (i, subview) in subviews.enumerated() {
            let from = frames[i]
            let to: CGRect
            if i == open {
                to = CGRect(origin: bounds.origin, size: opened)
            } else {
                // Out of the block, the shortest way: a card above the open one leaves by the
                // top, one below by the bottom, one beside it sideways. Not all of them down
                // past the open card — a column of cards sliding the length of the panel is
                // more movement than the opening itself, and half of it goes the wrong way.
                to = exit(from, past: open.flatMap { $0 < frames.count ? frames[$0] : nil }, in: bounds)
            }
            let frame = CGRect(x: from.minX + (to.minX - from.minX) * progress,
                               y: from.minY + (to.minY - from.minY) * progress,
                               width: from.width + (to.width - from.width) * progress,
                               height: from.height + (to.height - from.height) * progress)
            subview.place(at: frame.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where a card that is not the open one goes: off the nearest edge of the block, which
    /// clips it. It fades on the way — see the grid's own `opacity`.
    private func exit(_ from: CGRect, past open: CGRect?, in bounds: CGRect) -> CGRect {
        guard let open else { return from }
        var out = from
        if from.maxY <= open.minY {
            out.origin.y = bounds.minY - from.height - spacing
        } else if from.minY >= open.maxY {
            out.origin.y = bounds.minY + openHeight + spacing
        } else {
            out.origin.x = from.minX
                + (from.minX >= open.minX ? 1 : -1) * (width + spacing)
        }
        return out
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

/// One working directory, as a card: folded, its name, a dot per session in that session's own
/// state colour, and the count — the same rectangle a session gets, in the one colour no state
/// wears. Open, the same rectangle grown to the whole block, with its sessions inside its own
/// border: the directory is the thing you are looking at, and the rest of the fleet is pushed
/// out the bottom rather than left half-visible underneath it. One that fits is open from the
/// start, in the grid and only as tall as its cards — see `FleetLayout.unfolding`.
struct GroupTile: View {
    let name: String
    let sessions: [Session]
    /// Its sessions as cards rather than as lines: unfolded in the grid, or given the block.
    let open: Bool
    /// Whether a click opens it or folds it back. Not one that stands unfolded in the grid
    /// (asked 2026-10-12): its sessions are in view already, and it carries no arrow.
    var toggles = true
    /// ⌘-click goes to the head's terminal; a plain click only unfolds.
    let commandHeld: Bool
    /// Whether its sessions stand two to a row on the larger cards — see `most`.
    var large: Bool
    var spacing: CGFloat
    /// The block's size, which its cards are laid out at from the start: the card's
    /// own border is what cuts them while it grows. Following the card instead, their scroll
    /// view was resized at every frame of a fold.
    var full: CGSize
    /// Offscreen renders drop the scroll container, which never materialises its rows.
    var scrolling = true
    let onToggle: () -> Void
    let onActivate: (Session) -> Void

    /// The group colour. Teal because every other hue on the panel is spoken for by a state —
    /// green ready, red working, blue asking, amber failing, purple delegated, yellow held —
    /// and a card that borrowed one of those would read as a session in that state.
    static let tint = Color(red: 0.16, green: 0.82, blue: 0.80)

    /// One size, open or folded. The name only moves: a title that also shrank was a second
    /// thing happening in an animation that is already a card growing.
    /// The size a session's name has on the grid (asked 2026-10-15: smaller).
    private static let nameSize: CGFloat = 31 * 0.9 * 0.75
    /// Roughly the name's line height, to centre it on the folded card's 33% mark.
    private static let nameLine: CGFloat = 25

    /// What the open card keeps clear between its border and its cards, at the sides and
    /// under them. Half of what it was (asked 2026-10-12), which was the gap between two cards
    /// and 12 pt more for a card's glow.
    static func margin(_ spacing: CGFloat) -> CGFloat { (spacing + 12) / 2 }
    /// What its cards keep clear above them: the name's line, and the room above and under
    /// it, halved with the rest.
    static func top(_ spacing: CGFloat) -> CGFloat { spacing / 2 + nameLine + 17 }
    /// What two of its cards keep between them, across and down: half the grid's own gap
    /// (asked 2026-10-12), and the cards take the width. A hovered card's glow is wider than
    /// that, and meets the cards beside it.
    static func gap(_ spacing: CGFloat) -> CGFloat { spacing / 2 }
    /// What the card takes with every one of its sessions in view and nothing to scroll: the
    /// rows, and what `Cards` pads them with. No wider than its fullest row (asked
    /// 2026-10-12): a directory of two on a row of three ended on an empty place.
    /// On the smaller cards it is the grid's own cells, as many as it holds — see `flush`.
    static func size(holding count: Int, large: Bool, in width: CGFloat, spacing: CGFloat) -> CGSize {
        let perRow = perRow(count, large: large)
        let across = CGFloat(perRow), rows = CGFloat((count + perRow - 1) / perRow)
        if !large {
            let cell = cell(width, spacing: spacing)
            return CGSize(width: across * (cell.width + spacing) - spacing,
                          height: rows * (cell.height + spacing) - spacing)
        }
        let inner = inner(width, large: large, spacing: spacing)
        return CGSize(
            width: 2 * margin(spacing) + across * (inner + gap(spacing)) - gap(spacing),
            height: top(spacing) + rows * (SessionTile.height(width: inner) + gap(spacing)) - gap(spacing) + margin(spacing))
    }
    /// One cell of the grid a block this wide holds, three to a row.
    static func cell(_ width: CGFloat, spacing: CGFloat) -> CGSize {
        let across = CGFloat(most(large: false))
        let cell = (width + spacing) / across - spacing
        return CGSize(width: cell, height: SessionTile.height(width: cell))
    }
    /// What it takes of a block `room` tall that it has to itself: the whole of it (asked
    /// 2026-10-13), not what its cards need, which left the block half empty under a short
    /// directory. On the larger cards where they all fit; past the block they scroll.
    static func alone(holding count: Int, room: CGFloat, in width: CGFloat,
                      spacing: CGFloat) -> (large: Bool, size: CGSize) {
        let large = size(holding: count, large: true, in: width, spacing: spacing).height <= room
        return (large, CGSize(width: width, height: room))
    }
    /// The most sessions that stand side by side inside the open card. Two, on larger
    /// cards, where there is the room for it (asked 2026-10-12); three where there is not,
    /// on cards made smaller for it — see `inner` — so that a directory of several still fits
    /// unfolded.
    static func most(large: Bool) -> Int { large ? 2 : 3 }
    /// How many of `count` do: no more than its rows need, so four on the smaller cards
    /// stand two and two rather than three and one beside two empty places.
    static func perRow(_ count: Int, large: Bool) -> Int {
        let rows = max(1, (count + most(large: large) - 1) / most(large: large))
        return max(1, (count + rows - 1) / rows)
    }
    /// The width a session card gets inside the open card: the block, less the card's own
    /// padding, split between as many as can stand on a row.
    static func inner(_ width: CGFloat, large: Bool, spacing: CGFloat) -> CGFloat {
        let across = CGFloat(most(large: large))
        return (width - (across - 1) * gap(spacing) - 2 * margin(spacing)) / across
    }
    /// Standing in the grid on the smaller cards: its sessions in the grid's own cells, its
    /// border round them out in the gaps, and its name on that border over the corners where
    /// they meet (asked 2026-10-15). Two of them take two cells' room, and a session stands
    /// in the third.
    private var flush: Bool { open && !toggles && !large }
    /// How far out into the grid's gaps the border of a flush group stands from its cells
    /// (asked 2026-10-15: a border round them still), well short of the gap's middle so that
    /// it reads as theirs.
    private static let rim: CGFloat = 8
    /// What the open cards are called as a whole, to scroll back to their top.
    private static let cards = "cards"

    @State private var hovering = false
    /// How far the open group has been scrolled, so the name can travel with the cards it
    /// heads. Left where it is, it sat over the rows sliding under it.
    @State private var scrolled: CGFloat = 0

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .topLeading) {
                // Both faces of the card are kept, and a click only changes which one shows.
                // Built at the click, the cards were most of what that click's frame cost —
                // 17 to 29 ms for three sessions, against 6 with them already there
                // (`--bench-panel`, 12-10) — and the move starts once that frame is out.
                Cards(name: name, sessions: sessions, open: open, large: large, flush: flush,
                      spacing: spacing, size: full, scrolling: scrolling, scrolled: $scrolled,
                      onActivate: onActivate)
                    // Held to the card's own size as far as the stack goes: left to their
                    // full one, they pushed the count and the arrow out past the border.
                    .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
                // A dot per session said how many and in what state and nothing about what
                // any of them was doing — on a group of ten, the one thing worth the space.
                // A line each says it, and the ones past the third row are scrolled to.
                folded
                    .padding(.horizontal, 12)
                    // Two whole rows between the name and the border of a 16:9 card, not one
                    // and the top of the next.
                    .padding(.top, 12 + SessionTile.height * 0.33 + Self.nameLine / 2 + 6)
                    .padding(.bottom, 8)
                    .opacity(open ? 0 : 1)
                    .allowsHitTesting(!open)
                    .accessibilityHidden(open)

                // One text, two places. Not a folded name and an open one: those are two views,
                // so SwiftUI fades the first out and the second in, and the name blinks while
                // the card around it glides. This is the same `Text` at both ends, moved and
                // scaled — which is what a name sliding into the corner actually is.
                Text(name)
                    .font(.system(size: Self.nameSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    // Centred in both states, on the same width: the title does not change
                    // size, it only travels.
                    .offset(x: max(12, (box.size.width - nameWidth) / 2),
                            y: open ? spacing / 2 - scrolled : Self.titleTop)
                    .opacity(flush ? 0 : 1)

                HStack(spacing: 7) {
                    count
                    if toggles { chevron }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(11)
                .opacity(flush ? 0 : 1)

                if flush {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Self.tint)
                        .lineLimit(1)
                        .fixedSize()
                        .titleGround(1)
                        .frame(maxWidth: .infinity)
                        // Centred on the cells' top edge, over their corners and the border's
                        // line: on the line itself, the grid's top row cut it.
                        .offset(y: -9.5)
                }
            }
            // A group that is folded up and opened again starts at the top, and a name still
            // carrying the last scroll would be drawn off the card.
            .onChange(of: open) { scrolled = 0 }
            // The empty room inside the card belongs to the directory: clicking it opens it,
            // and clicking it again folds it back up rather than falling through to the
            // panel's dismiss layer. The cards inside are buttons and take their own clicks.
            .contentShape(Rectangle())
            .onTapGesture(perform: tapped)
        }
        // Nothing leaves the border, neither a row past the bottom nor a card's hover glow.
        // Standing in the grid the border is out in the gaps, and the name and the cells'
        // glow reach it.
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: flush ? -30 : 0))
        .background(
            RoundedRectangle(cornerRadius: flush ? 10 + Self.rim : 10, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                .shadow(color: Self.tint.opacity(hovering ? 0.45 : 0.18),
                        radius: hovering ? 16 : 8)
                .padding(flush ? -Self.rim : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: flush ? 10 + Self.rim : 10, style: .continuous)
                .strokeBorder(Self.tint, lineWidth: 2.5)
                .padding(flush ? -Self.rim : 0)
        )
        // Only the folded card lifts to the pointer: the open one is the size of the block,
        // and a block that grows under the pointer pushes its own contents around.
        .scaleEffect(!open && hovering ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
    }

    /// Where the name's own line starts, measured from the top of the folded card.
    static let titleTop: CGFloat = 12 + SessionTile.height * 0.33 - nameLine / 2

    /// The name's width at rest, measured rather than laid out: the text is placed by hand, so
    /// centring it on the folded card needs a number before anything is drawn.
    private var nameWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.nameSize, weight: .semibold)
        return (name as NSString).size(withAttributes: [.font: font]).width
    }

    /// The sessions, under the name. Scrolled, not stacked: nine sessions are five rows and the
    /// card is the height of the block, so without this the rows ran straight through its own
    /// border and over whatever the grid had underneath.
    ///
    /// A view of its own, handed nothing that changes while the card grows: a frame of the
    /// fold re-runs the card's body for its new size, finds these inputs as they were, and
    /// leaves the cards alone instead of going through every one of them again.
    private struct Cards: View {
        let name: String
        let sessions: [Session]
        let open: Bool
        let large: Bool
        /// The grid's own cells, at the grid's own gaps, with nothing round them — see
        /// `GroupTile.flush`.
        let flush: Bool
        let spacing: CGFloat
        let size: CGSize
        let scrolling: Bool
        @Binding var scrolled: CGFloat
        let onActivate: (Session) -> Void

        var body: some View {
            let head = Session.heads[name]
            let ordered = GroupTile.ordered(sessions, head: head)
            let perRow = GroupTile.perRow(ordered.count, large: large)
            let inner = GroupTile.inner(size.width, large: large, spacing: spacing)
            let card = flush ? GroupTile.cell(size.width, spacing: spacing)
                             : CGSize(width: inner, height: SessionTile.height(width: inner))
            let between = flush ? spacing : GroupTile.gap(spacing)
            let lines = stride(from: 0, to: ordered.count, by: perRow).map {
                Array(ordered[$0 ..< min($0 + perRow, ordered.count)])
            }
            let rows = VStack(alignment: .leading, spacing: between) {
                ForEach(lines, id: \.first?.id) { row in
                    HStack(alignment: .top, spacing: between) {
                        ForEach(row) { session in
                            // Inside a directory the card wears its topic: the directory is
                            // what these sessions have in common, and a row of cards all
                            // saying "portfolio" is a row you cannot choose from.
                            SessionTile(session: session, heading: session.label ?? session.topic,
                                        main: session.id == head, grouped: true, large: large) {
                                onActivate(session)
                            }
                            .frame(width: card.width, height: card.height)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Every gap the cards keep is inside the scroll view, not around it: a scroll view
            // clips its own content, so room left outside it is room the hover glow never
            // reaches — the top-left card lost its glow on the two sides facing the border.
            // The distances are the ones that were here before; what moved is where the clip
            // falls, which is now the group's own border.
            //
            // Clear of the name, which is drawn over this rather than above it — and clear by
            // a margin: a row of cards starting five points under the title read as its
            // underline.
            .padding(.top, flush ? 0 : GroupTile.top(spacing))
            .padding([.horizontal, .bottom], flush ? 0 : GroupTile.margin(spacing))

            Group {
                // Standing in the grid it fits by construction, and a scroll view the size of
                // the block would take the pointer off the cards around it.
                if scrolling && !flush {
                    ScrollViewReader { reader in
                        ScrollView(.vertical) { rows.id(GroupTile.cards) }
                            .scrollIndicators(.hidden)
                            .scrollBounceBehavior(.basedOnSize)
                            // The name is drawn over this rather than in it — see the card's
                            // `body` — so it has to be told how far the cards have moved.
                            // Clipped by the group's own border on the way out, which is
                            // where a heading should go.
                            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: {
                                _, y in scrolled = y
                            }
                            // The cards outlive the fold now, and so does how far they were
                            // scrolled: sent back up as the group opens, before they can be
                            // seen.
                            .onChange(of: open) {
                                if open { reader.scrollTo(GroupTile.cards, anchor: .top) }
                            }
                    }
                } else {
                    rows
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
    }

    /// The head first, top left, whatever it was touched last: it is the card you came for.
    /// One order for the folded lines and the open cards, so the first of either is what ⌘ opens.
    static func ordered(_ sessions: [Session], head: pid_t?) -> [Session] {
        sessions.sorted { a, _ in a.id == head }
    }

    private var ordered: [Session] { Self.ordered(sessions, head: head?.id) }

    /// A plain click unfolds, which costs nothing and undoes itself. ⌘ goes straight to the
    /// head's terminal, which closes the panel and can change Space with nothing to click to
    /// come back — so it is asked for, never stumbled into.
    private func tapped() {
        if commandHeld, let head { onActivate(head) } else if toggles { onToggle() }
    }

    /// The group's head: the session the others name as the sender of their brief. A peer
    /// message carries `from="uds:/tmp/cc-socks/<pid>.sock"`, and that pid is one of these
    /// cards — so the panel works out who is driving from its own data rather than from a
    /// directory named `main-*`.
    ///
    /// Nothing to go on — nobody in this group has briefed anybody — and it is the one that
    /// started first. Not the most recent: a head that moves every time a card wakes up is a
    /// head you cannot aim at.
    /// The group's head — the session the others name as the sender of their brief, elected
    /// once by `AppController` and kept until somebody new joins the group. Worked out there
    /// rather than here because the sessions themselves are told about it: a head's own status
    /// line says so.
    var head: Session? {
        guard let pid = Session.heads[name] else { return nil }
        return sessions.first { $0.id == pid }
    }



    /// A line per session, under the name: its state as a dot, then what it is doing. The
    /// head is the brighter line, and the one ⌘ is aimed at — which is why it lights up while
    /// ⌘ is down rather than only once the click has been spent.
    @ViewBuilder private var folded: some View {
        // Two to a row past three: the card has room for three rows, and a group of seven
        // showed three of its sessions. Row by row, as the open cards are laid.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0),
                            count: ordered.count > 3 ? 2 : 1)
        let rows = LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            ForEach(ordered) { session in
                let isHead = session.id == head?.id
                HStack(spacing: 7) {
                    Circle().fill(session.state.tint).frame(width: 7, height: 7)
                    Text(session.label ?? session.topic)
                        .font(.system(size: 10.5, weight: isHead ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(isHead ? 0.92 : 0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if scrolling {
                ScrollView(.vertical) { rows }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    // The name is drawn over this rather than in it — see `body` — so it has
                    // to be told how far the cards have moved. Clipped by the group's own
                    // border on the way out, which is where a heading should go.
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: {
                        _, y in scrolled = y
                    }
            } else {
                rows
            }
        }
        // The rows are a readout, not a menu: a click on one means what a click beside it
        // means. Simultaneous rather than a gesture of their own, so the scroll still works
        // and the tap still reaches the card under it.
        .simultaneousGesture(TapGesture().onEnded(tapped))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var count: some View {
        Text("\(sessions.count)")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Self.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Self.tint.opacity(0.14), in: Capsule())
    }

    /// One arrow, turned — not a right-pointing one swapped for a down-pointing one. Two
    /// symbols are two views: SwiftUI fades the first out and the second in, so the arrow
    /// blinked where the card it belongs to glides.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Self.tint.opacity(0.8))
            .rotationEffect(.degrees(open ? 90 : 0))
    }
}

/// The head's name lit in the group's own colour. On that card only: at opacity 0 on every other
/// one, the two shadows were still two offscreen passes per tile per frame (28-09: 18 of the
/// panel's 26 shadows without a path, tick 33 ms).
struct HeadGlow: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .shadow(color: GroupTile.tint.opacity(0.55), radius: 10)
                .shadow(color: GroupTile.tint.opacity(0.35), radius: 22)
        } else {
            content
        }
    }
}

/// One session, read at a glance: the name and the state border. Everything else is a
/// distraction at this size; `--scan` is there when you want the details.
struct SessionTile: View {
    let session: Session
    /// What the card is called, when the directory name it defaults to would say nothing —
    /// inside an unfolded group, where every card shares that directory.
    var heading: String?
    /// Whether this is the group's head: its name glows. Not written over it (asked 2026-09-28):
    /// the head is always the first card, top left.
    var main = false
    /// Inside an unfolded group, whose heading already names the directory: no folder in the
    /// corner, which leaves the pills the whole line.
    var grouped = false
    /// Inside a group that stands two to a row: a taller card, and the name at the size a
    /// topic has on the grid's own.
    var large = false
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
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                    .shadow(color: session.state.tint.opacity(hovering ? 0.45 : 0.18),
                            radius: hovering ? 16 : 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(session.state.tint, lineWidth: 2.5)
            )
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
            // Smaller on 2026-10-15: 0.9 of what it was, then on the grid 0.75 of that.
            .font(.system(size: grouped ? (large ? 22 : 15) * 0.9 : (heading == nil ? 31 : 22) * 0.9 * 0.75,
                          weight: .semibold))
            .foregroundStyle(.white)
            .modifier(HeadGlow(on: main))
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
            .truncationMode(.head)
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
        // gauge: a dark pane filled from the left to the share of the RAM in use. Every other
        // block is a flat tint because every other block is a count of things; this is a level.
        return Block(title: "MEMORY",
                     titleColor: tight ? tint : .white.opacity(0.92),
                     tint: ramTint.opacity(0.45),
                     fill: .black.opacity(0.41),
                     level: BlockLevel(share: share(reaper.footprint.used), tint: ramTint.opacity(0.42)),
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
                + Text(" \u{00B7} \(gigabytes(reaper.footprint.total))").foregroundColor(.white.opacity(0.9)))
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

    /// What colour the block is: the share of the RAM in use, on the scale the figure itself
    /// used to be drawn in — and red outright once Fleet is holding sessions back, whatever
    /// the share says.
    private var ramTint: Color {
        if reaper.struggling { return SessionState.running.tint }
        return Self.scale(share(reaper.footprint.used), 0.60, 0.75, 0.88) ?? BlockTint.memory
    }

    private func share(_ bytes: UInt64) -> Double {
        let total = reaper.footprint.total
        return total > 0 ? Double(bytes) / Double(total) : 0
    }

    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    /// A machine's RAM is a round number of gigabytes, and the tenth on the end of it was one
    /// digit of noise beside a figure that changes.
    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }

    /// Why the block is amber, in the few words the heading has room for. The long version of
    /// the same sentence is what the sessions are told — see `Hooks.machinePath`.

    /// How full the RAM is — the figure itself, since the gigabytes behind it say less at a
    /// glance than the share does.
    private var percentLabel: String { percent(share(reaper.footprint.used)) }

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
    /// A dark chip behind a column's name. The panel is a wash over your desktop, and a
    /// heading standing on a bright wallpaper is a heading you have to hunt for.
    ///
    /// Not a material: macOS's blur has a fixed radius, and the panel already turned frosted
    /// glass down for that reason. The negative padding puts the chip outside the text's own
    /// bounds, so nothing on the heading line moves.
    /// The outline around a whole block, in the block's own colour, with the heading inside it
    /// like MEMORY's: 13pt of pane over the name, as on the other three sides. It used to run
    /// through the middle of the heading line, broken by the chips; asked on 2026-09-27 to take
    /// the names in, like MEMORY and REELS.
    ///
    /// Drawn outside the block's own bounds rather than padded into them, so hanging a frame on
    /// a column moves nothing inside it: the cards keep the width they had.
    /// `bottomSpread` pour les blocs qui gardent de la place en bas à l'intérieur — le fleet
    /// laisse 20pt sous la dernière rangée pour le halo au survol. Sans lui, ces 20pt
    /// s'ajoutent au débord et le noir descend deux fois plus bas sur le bas que sur les côtés.
    func blockFrame(_ tint: Color, fill: Color? = nil, spread: CGFloat = 13,
                    bottomSpread: CGFloat? = nil, topSpread: CGFloat = 13,
                    level: BlockLevel? = nil) -> some View {
        background(alignment: .top) {
            let corner = RoundedRectangle(cornerRadius: 12, style: .continuous)
            corner
                // The same colour as the line, laid over the panel's black scrim — which
                // is what darkens it. A block is tinted, not coloured: the cards inside are
                // opaque and keep their own near-black, so this only ever shows in the margins.
                // Darkened rather than thinned: the hue is taken down towards black first,
                // so it stays its own colour. The sliver of transparency on top only lets
                // the desktop show through the margins.
                .fill((fill ?? tint.darkened(0.48)).opacity(0.78))
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
    /// Gris, comme SOCIAL MEDIA : ces deux blocs constatent, ils ne demandent rien. Seule la
    /// jauge de RAM garde une couleur, et elle la tient de son propre taux.
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
