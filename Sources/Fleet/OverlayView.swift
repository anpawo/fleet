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

    /// Which directory is unfolded. On the controller, not here: Esc and the panel chord fold
    /// it before they dismiss, and a piece of `@State` is not something they can reach. It is
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

    /// The directory the grid last had open. Survives the close so the card has somewhere to
    /// shrink back to — cleared by nothing, since the next open overwrites it.
    @State private var lastGroup: String?

    /// Opening a directory moves every other card at once. Cut rather than animated, the grid
    /// reads as a different grid each click.
    private static let unfold = Animation.easeOut(duration: 0.28)


    /// Fixed tiles per row and fixed width, rather than adaptive: a partial last row, and a
    /// one-session fleet, start at the same left edge as every full row rather than drifting
    /// to the middle. A lone tile that centres itself reads as a different column each time
    /// the fleet is odd-numbered.
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
    private let sideWidth: CGFloat = 288

    /// How the leftover width is shared out: 2 : 3 : 3 : 2, edges to insides. Ratios rather
    /// than points, so the balance holds on a laptop screen and on a 34-inch one — a fixed
    /// margin on a wide display would pin the columns to the bezel and leave the middle adrift.
    private static let edgeWeight = 2
    private static let innerWeight = 3

    /// The one space between two blocks of a side column. A frame reaches 13pt below its
    /// content and its own line sits 7pt down from the top of the next, so what the eye sees
    /// is twenty-six of this.
    private static let blockGap: CGFloat = 32

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

    /// As tall as the screen has room for between those two gaps — the ceiling a column
    /// scrolls or is cut off under, rather than a height it takes.
    /// What a block is told to be, against the `columnHeight` its column is clipped to: a
    /// block's frame is drawn `blockSpread` past its content on every side — see `blockFrame`
    /// — and a block as tall as the clip lost its own bottom edge to it.
    static var blockHeight: CGFloat { columnHeight - blockSpread }

    static var columnHeight: CGFloat {
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
                // The step the podium leaves above the mail is exactly where the machine's own
                // state belongs: the one thing on the panel that is not about Claude at all,
                // in the corner, at the width of the column it sits over. A minimum rather
                // than a height — under pressure the hogs need more rows, and an alert that
                // shoves the column down is an alert doing its job.
                // One gap, three blocks: the machine's own two lines, the mail and the
                // school. Every space between them is the same space — a column whose gaps
                // vary reads as groups nobody meant to make.
                VStack(alignment: .leading, spacing: Self.blockGap) {
                    MemoryStrip(reaper: controller.reaper,
                                commandHeld: controller.commandHeld)
                    // What is left of the column once the memory has had its line, three
                    // sevenths to the mail and four to the school. The school lost its mail lines — it
                    // is twelve module cards now, and they are shorter — while the mail is the
                    // list you actually work. Both scroll inside their share, so neither can
                    // push the other off the bottom of the panel.
                    GeometryReader { space in
                        let free = space.size.height - Self.blockGap
                        VStack(alignment: .leading, spacing: Self.blockGap) {
                            MailColumn(hub: controller.hub,
                                       commandHeld: controller.commandHeld,
                                       scrolling: !eagerLayout)
                                .frame(height: max(0, free * 3 / 7))
                            EpitechColumn(hub: controller.hub,
                                          commandHeld: controller.commandHeld,
                                          onDismiss: { controller.hidePanel() },
                                          scrolling: !eagerLayout)
                                .frame(height: max(0, free * 4 / 7))
                        }
                    }
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
                .padding(.top, Self.blockSpread)
                // Rounded, not squared off: what the cut lands on is a card, and a card
                // sliced on a straight line reads as a drawing error rather than a list
                // carrying on past the edge.
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, -Self.blockSpread)
                .padding(.top, -Self.blockSpread)
                gap(Self.innerWeight)
            }
            fleet(scrolling: scrolling)
                .frame(width: centerWidth, height: Self.blockHeight, alignment: .top)
                // What is broken rides over the fleet, centred, and only when something is —
                // see `AlertsBlock`. Hung over the top edge rather than stacked on it: in the
                // stack it pushed the whole fleet down the axis the day something broke, and a
                // grid that moves is a grid you have to find again. The panel leaves 126pt of
                // room above this line, so the bar has somewhere to hang.
                .overlay(alignment: .top) {
                    if !AlertsBlock.alerts(controller.hub).isEmpty {
                        AlertsBlock(hub: controller.hub)
                            // As wide as the block it hangs over, and clear of its heading
                            // line: its own height, and the gap a block leaves under one.
                            .frame(width: centerWidth)
                            .offset(y: -(AlertsBlock.height + 34))
                    }
                }
            if controller.hub.isConfigured {
                gap(Self.innerWeight)
                // The two agent blocks take what their cards need and no more, a third of the
                // column at the most; the list has the rest. Five agents under a block sized
                // for fifteen was a third of the column of blue paper.
                //
                // No podium here: both start on the fleet's own line. They are the other
                // lists you are answerable to, and a step below the sessions read as a
                // footnote to them.
                GeometryReader { space in
                    let free = space.size.height - 2 * Self.blockGap
                    VStack(alignment: .leading, spacing: Self.blockGap) {
                        CronColumn(title: "ROUTINE", jobs: controller.launchd.crons,
                                   commandHeld: controller.commandHeld,
                                   scrolling: !eagerLayout, limit: max(0, free / 3))
                        // Half rather than a third, unlike ROUTINE above: a resident carries
                        // the address it answers on under its name, so its cards are two lines
                        // where a routine's are one. A block only ever takes what its cards
                        // need, so a ceiling nobody reaches costs the list underneath nothing.
                        CronColumn(title: "KEEP ALIVE", jobs: controller.launchd.alive,
                                   commandHeld: controller.commandHeld,
                                   scrolling: !eagerLayout, limit: max(0, free / 2))
                        TodoColumn(hub: controller.hub,
                                   commandHeld: controller.commandHeld,
                                   onDismiss: { controller.hidePanel() },
                                   scrolling: !eagerLayout)
                            .frame(maxHeight: .infinity)
                    }
                    // Pinned to the top of the column. The two agent blocks take only what
                    // their cards need, so the stack is shorter than the space it is given —
                    // and a stack left to sit in the middle of that space starts the routines
                    // below the fleet's own line.
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
        VStack(alignment: .leading, spacing: 0) {
            fleetHeading
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
        // Wider than a column's: a tile's hover glow reaches 22pt past the grid, and a frame
        // inside that is a line the cards wipe over every time the pointer crosses one.
        .blockFrame(BlockTint.fleet, fill: .black.opacity(0.71), spread: 26, bottomSpread: 13)
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
                    .foregroundStyle(.white.opacity(0.92))
                    .titleGround()
                Spacer(minLength: 3)
                if !controller.sessions.isEmpty {
                    Text("\(controller.sessions.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .titleGround()
                }
            }

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
        .padding(.horizontal, 2)
        // The room the scroll view below needs to start clear of the heading rather than under
        // it: the tiles are clipped at this line instead of riding over the name.
        .padding(.bottom, 9)
    }

    /// The sessions gathered by the directory they are working in, in the order the sessions
    /// themselves already come in — least recently touched first, so the group holding the
    /// session you have left alone longest leads.
    private func groups(of sessions: [Session]) -> [(name: String, sessions: [Session])] {
        var order: [String] = []
        var byDir: [String: [Session]] = [:]
        for session in sessions {
            if byDir[session.groupName] == nil { order.append(session.groupName) }
            byDir[session.groupName, default: []].append(session)
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
        guard let name = openGroup ?? lastGroup else { return nil }
        return cells.firstIndex { $0.id == "dir:" + name }
    }

    /// Whether this card is the directory that is open.
    private func isOpen(_ cell: FleetCell) -> Bool {
        guard let name = openGroup else { return false }
        return cell.id == "dir:" + name
    }

    /// How tall the open card is: the room the grid has. Offscreen nothing has been laid out
    /// to measure, so a fleet's worth of rows stands in.
    private var openHeight: CGFloat {
        gridSpace > 0 ? gridSpace - Self.gridPadding
                      : max(0, Self.blockHeight - Self.gridPadding - 132)
    }

    /// The width a session card gets inside an open directory: the block, less the directory
    /// card's own padding, split in two.
    private var innerTileWidth: CGFloat {
        (centerWidth - 3 * tileSpacing) / 2
    }

    /// Every card, in rows of two, laid out by hand rather than by stacks — see `FleetLayout`.
    /// One view per card, whatever is open: the card you click is the card that grows, moving
    /// and resizing from where it sits to the whole block, and the others are placed off the
    /// bottom edge on the way out. Nested stacks could not do that. A card in one row and a
    /// block at the top are two different places in the view tree, so the first was removed and
    /// the second inserted — the card blinked out of the grid and the block arrived from above.
    private var grid: some View {
        FleetLayout(tile: CGSize(width: tileWidth, height: SessionTile.height),
                    spacing: tileSpacing, columns: Self.tilesPerRow,
                    open: openIndex, openHeight: openHeight,
                    progress: openGroup == nil ? 0 : 1) {
            ForEach(cells) { cell in
                Group {
                    switch cell {
                        case let .group(name, sessions):
                        GroupTile(name: name, sessions: sessions,
                                  open: openGroup == name,
                                  commandHeld: controller.commandHeld,
                                  inner: innerTileWidth, spacing: tileSpacing,
                                  scrolling: !eagerLayout,
                                  onToggle: {
                                      lastGroup = name
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
/// Two columns of a fixed card, and — when a directory is open — that one card taking the whole
/// block at the top left while every other card is placed past the bottom edge, where the block
/// clips them away.
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
    /// The card that is opening — or the one that was open and is folding back up. Kept
    /// through the close, since a card that loses its place the moment you click has nothing
    /// to shrink back from.
    var open: Int?
    /// What the open card is given: the room the grid has.
    var openHeight: CGFloat
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Open, the grid is exactly the open card: the others are off the bottom, and counting
        // them would give the scroll view somewhere to scroll them back into view.
        let folded = rows(subviews.count)
        return CGSize(width: width, height: folded + (openHeight - folded) * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        for (i, subview) in subviews.enumerated() {
            let from = slot(i, in: bounds, at: i, drop: 0)
            let to: CGRect
            if i == open {
                to = CGRect(origin: bounds.origin, size: CGSize(width: width, height: openHeight))
            } else {
                // Out of the block, the shortest way: a card above the open one leaves by the
                // top, one below by the bottom, one beside it sideways. Not all of them down
                // past the open card — a column of cards sliding the length of the panel is
                // more movement than the opening itself, and half of it goes the wrong way.
                to = exit(from, mine: i, open: open, in: bounds)
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
    private func exit(_ from: CGRect, mine: Int, open: Int?, in bounds: CGRect) -> CGRect {
        guard let open else { return from }
        var out = from
        let row = mine / columns, column = mine % columns
        let openRow = open / columns, openColumn = open % columns
        if row < openRow {
            out.origin.y = bounds.minY - tile.height - spacing
        } else if row > openRow {
            out.origin.y = bounds.minY + openHeight + spacing
        } else {
            out.origin.x = from.minX
                + (column >= openColumn ? 1 : -1) * (width + spacing)
        }
        return out
    }

    private func slot(_ i: Int, in bounds: CGRect, at index: Int, drop: CGFloat) -> CGRect {
        let column = index % columns, row = index / columns
        return CGRect(x: bounds.minX + CGFloat(column) * (tile.width + spacing),
                      y: bounds.minY + drop + CGFloat(row) * (tile.height + spacing),
                      width: tile.width, height: tile.height)
    }
}

/// What the grid holds: a directory, or one of its sessions.
enum FleetCell: Identifiable {
    case group(String, [Session])
    case session(Session, heading: String?)

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
/// out the bottom rather than left half-visible underneath it.
struct GroupTile: View {
    let name: String
    let sessions: [Session]
    let open: Bool
    /// ⌘ down turns the `main` badge into a button: a plain click anywhere on this card
    /// unfolds it, which is free and reversible, and going to the terminal is neither — it
    /// closes the panel and can change Space with nothing to click to come back.
    let commandHeld: Bool
    /// What a session card inside is given, worked out by the grid from its own width.
    var inner: CGFloat
    var spacing: CGFloat
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
    private static let nameSize: CGFloat = 31
    /// Roughly the name's line height, to centre it on the folded card's 30% mark.
    private static let nameLine: CGFloat = 37

    @State private var hovering = false
    @State private var badgeHover = false

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .topLeading) {
                if open {
                    sessions(in: box.size)
                } else {
                    // One dot per session, so a folded directory still says what is waiting
                    // inside it — the glance the grid was for, kept through the fold. At the
                    // top since the foot of the card now carries the main session's line.
                    dots
                        .padding(.horizontal, 12)
                        .padding(.top, 13)
                    if let main {
                        // What the folded card is otherwise missing: a group of nine says how
                        // many and in what state, and nothing about what any of them is doing.
                        // The main is the one that knows, so it speaks for the group.
                        VStack(alignment: .leading, spacing: 5) {
                            mainBadge
                            Text(main.topic)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding([.horizontal, .bottom], 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }

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
                            y: open ? spacing
                                     : 12 + SessionTile.height * 0.30 - Self.nameLine / 2)

                HStack(spacing: 7) {
                    count
                    chevron
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(11)
            }
            // The empty room inside the card belongs to the directory: clicking it opens it,
            // and clicking it again folds it back up rather than falling through to the
            // panel's dismiss layer. The cards inside are buttons and take their own clicks.
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
        }
        // Nothing leaves the border, neither a row past the bottom nor a card's hover glow.
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                .shadow(color: Self.tint.opacity(hovering ? 0.45 : 0.18),
                        radius: hovering ? 16 : 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Self.tint, lineWidth: 2.5)
        )
        // Only the folded card lifts to the pointer: the open one is the size of the block,
        // and a block that grows under the pointer pushes its own contents around.
        .scaleEffect(!open && hovering ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
    }

    /// The name's width at rest, measured rather than laid out: the text is placed by hand, so
    /// centring it on the folded card needs a number before anything is drawn.
    private var nameWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.nameSize, weight: .semibold)
        return (name as NSString).size(withAttributes: [.font: font]).width
    }

    /// The sessions, under the name. Scrolled, not stacked: nine sessions are five rows and the
    /// card is the height of the block, so without this the rows ran straight through its own
    /// border and over whatever the grid had underneath.
    @ViewBuilder private func sessions(in size: CGSize) -> some View {
        let rows = VStack(alignment: .leading, spacing: spacing) {
            ForEach(self.rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row) { session in
                        // Inside a directory the card wears its topic: the directory is what
                        // these sessions have in common, and a row of cards all saying
                        // "portfolio" is a row you cannot choose from.
                        SessionTile(session: session, heading: session.topic) {
                            onActivate(session)
                        }
                        .frame(width: inner)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if scrolling {
                ScrollView(.vertical) { rows }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                rows
            }
        }
        // Clear of the name, which is drawn over this rather than above it — and clear by a
        // margin: a row of cards starting five points under the title read as its underline.
        .padding(.top, spacing + Self.nameLine + 34)
        .padding([.horizontal, .bottom], spacing)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var rows: [[Session]] {
        stride(from: 0, to: sessions.count, by: 2).map {
            Array(sessions[$0 ..< min($0 + 2, sessions.count)])
        }
    }

    /// The session driving this group, if one of them is.
    private var main: Session? { sessions.first(where: \.isMain) }

    /// The one word that says which of these cards is the control post — and, with ⌘ down, the
    /// only thing on a folded card that opens a terminal. It lights up under the pointer so
    /// the gesture is announced before it is spent, which the card itself never does: nothing
    /// in this app changes the cursor.
    @ViewBuilder private var mainBadge: some View {
        let armed = commandHeld && badgeHover
        Text("MAIN")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(armed ? Color.black : Self.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(armed ? Self.tint : Self.tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Self.tint.opacity(commandHeld ? 0.9 : 0),
                                            lineWidth: 1))
            .contentShape(Capsule())
            .onHover { badgeHover = $0 }
            .onTapGesture { if commandHeld, let main { onActivate(main) } }
            .animation(.easeOut(duration: 0.15), value: armed)
            .animation(.easeOut(duration: 0.15), value: commandHeld)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(sessions) { session in
                Circle().fill(session.state.tint).frame(width: 9, height: 9)
            }
        }
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

/// One session, read at a glance: the name, the state border, and — only while it is
/// working — the single step in flight. Everything else is a distraction at this size;
/// `--scan` is there when you want the details.
struct SessionTile: View {
    let session: Session
    /// What the card is called, when the directory name it defaults to would say nothing —
    /// inside an unfolded group, where every card shares that directory.
    var heading: String?
    let onSelect: () -> Void

    /// Sub-agent work gets its own colour rather than the state tint, and it is the same purple
    /// the border wears when the agents are the only thing running: one colour, one meaning —
    /// work happening on a thread that is not the one you would be talking to.
    static let subagentTint = SessionState.delegated.tint

    @State private var hovering = false

    /// Fixed so the name's 30% line is the same on every tile, whatever the history under it.
    static let height: CGFloat = 186
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
                    // One stack at the rail's own spacing: in the outer one, which has none, the
                    // sub-agent and step lines sat three points closer than the lines above them.
                    VStack(alignment: .leading, spacing: 3) {
                        rail
                        subagent
                        step
                    }
                }
                .padding([.horizontal, .top], 12)
                // Close to the border, clear of its 2.5 pt stroke.
                .padding(.bottom, (2.5 + 3) * 3)
                // Without this the stack is only as tall as its content, the flexible spacer
                // above the history has nothing to expand into, and the slack ends up below
                // the tile's content instead of above it — which is why the history sat high
                // whatever the spacers said.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                HStack(alignment: .top, spacing: 7) {
                    Spacer(minLength: 6)
                    subagentPill
                    statePill
                }
                .padding(11)
            }
            .frame(height: Self.height, alignment: .top)
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
        Text(heading ?? session.dirName)
            .font(.system(size: heading == nil ? 31 : 19, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(heading == nil ? 1 : 2)
            .multilineTextAlignment(.center)
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
            // What was said, not what was run: the grey tool lines crowded out the sentences.
            // One exception — the call a session is blocked on, which is why it needs you.
            let steps = session.steps
            let said = steps.enumerated().filter { index, line in
                line.kind != .tool || (session.state == .awaitingAnswer && index == steps.count - 1)
            }.map(\.element)
            // From your last message on, not the tail of the whole conversation: the line above
            // the question was the answer to the one before it. The question stays put when the
            // replies to it run past the room; they give up their oldest line instead.
            let lines: [PreviewLine] = said.lastIndex(where: { $0.kind == .user }).map { ask in
                [said[ask]] + said[(ask + 1)...].suffix(room - 1)
            } ?? Array(said.suffix(room))
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
        case .assistant: return "↳"
        case .tool: return "-"
        }
    }

    private func tint(for kind: PreviewLine.Kind) -> Color {
        switch kind {
        case .user: return Color(red: 0.42, green: 0.70, blue: 1.00)
        case .assistant: return SessionState.ready.tint
        case .tool: return .white.opacity(0.3)
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
                Text("*")
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
            Text("SUB-AGENTS: \(running)")
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
            // Never broken over two lines: "BACKGROUN / D" beside a sub-agent pill is what a
            // header short of room did to it.
            .fixedSize()
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

    private var amber: Color { Color(red: 1.00, green: 0.62, blue: 0.15) }

    /// How much of the RAM has to be on disk before swap is worth a pill of its own.
    private static let swapWorthSaying = 0.10

    var body: some View {
        let tight = reaper.struggling && !reaper.hogs.isEmpty
        let tint = tight ? amber : Color.white
        // "One line at rest" was written and never enforced: with nothing to put under the
        // heading the frame still ran 13pt past it, so an idle machine got a bar of empty
        // amber with a chip sitting on it. A block with nothing to say is the heading alone.
        let hasBody = tight || share(reaper.footprint.swap) >= Self.swapWorthSaying

        let stack = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("MEMORY")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3.2)
                    .foregroundStyle(tight ? tint : .white.opacity(0.92))
                    .titleGround()
                Spacer(minLength: 3)
                // The whole readout, where every other block puts its count. A heading over a
                // single line of figures is a heading over nothing: the block is one line at
                // rest, and it only grows when there is something to say underneath.
                // The share in the block's own colour — the same verdict the frame is painted
                // in, said twice on the one line where it can be read as a figure.
                (Text("RAM \u{00B7} ").foregroundColor(.white.opacity(0.9))
                    + Text(percentLabel).foregroundColor(ramTint)
                    + Text(" \u{00B7} \(gigabytes(reaper.footprint.total))").foregroundColor(.white.opacity(0.9)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .titleGround()
            }
            .padding(.horizontal, 2)

            // Under the rule rather than beside the name: the sentence is a sentence, and the
            // heading line is a name, a button and no room for a third thing.
            if tight {
                Text(headline)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(amber.opacity(0.9))
                    // Indented onto the pills' own text column, not the block's edge: the
                    // sentence and the names it explains start on the same line, and the two
                    // points it used to sit at put it eight left of everything under it.
                    .padding(.horizontal, HogPill.inset)
                    // Clear of the heading by about what the frame leaves under the last pill:
                    // at one point off the chip the sentence read as part of the title.
                    .padding(.top, 5)
            }

            // Two of the four. Cached is never a problem and compressed is a leading
            // indicator; neither is something you act on. What is worth a glance is how full
            // the RAM is and whether the machine has started paying disk latency for it —
            // and the amber state below, which is the kernel's own verdict, covers the rest.
            WeightedRow(weights: [2, 1], spacing: 4) {
                if tight {
                    // Under pressure the pills are the processes holding the memory, which is
                    // the only thing to do about it.
                    VStack(alignment: .leading, spacing: 5) {
                        if commandHeld {
                            // One after the other, each easing down out of the bar, so the eye
                            // follows the list as it forms rather than finding it there. Gone at
                            // once when ⌘ comes up: there is nothing to watch on the way out.
                            ForEach(Array(reaper.hogs.enumerated()), id: \.element.id) { index, hog in
                                HogPill(hog: hog, tint: amber)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: -8))
                                            .animation(.easeOut(duration: 0.4).delay(Double(index) * 0.09)),
                                        removal: .opacity.animation(.easeIn(duration: 0.12))))
                            }
                        }
                    }
                    .animation(.easeOut(duration: 0.4), value: commandHeld)
                } else {
                    let ram = reaper.footprint
                    // Not "when there is any". Swap used never comes back down — a page that
                    // has been written to disk stays counted until the machine reboots — so
                    // "> 0" meant "from the first time it ever paged until you restart", which
                    // is to say always. A Mac pages a few hundred megabytes in ordinary work
                    // and feels perfectly fine doing it; what is worth a pill is swap deep
                    // enough to be somewhere you are living, hence a share of the RAM rather
                    // than a byte count that means something different on every machine.
                    if share(ram.swap) >= Self.swapWorthSaying {
                        Reading("SWAP", byteLabel(ram.swap),
                                accent: share(ram.swap) < 0.25 ? SessionState.apiError.tint
                                                               : SessionState.running.tint)
                    }
                }
            }
            .padding(.horizontal, 2)
        }

        // The one block whose colour is a reading rather than a name. The RAM used to say it
        // on a capsule of its own, inside a block painted a fixed orange — two grounds, one
        // fact. The capsule is gone and the block carries it: green, blue, amber, red, on the
        // same four thresholds the figure was tinted by. The figure in the heading is tinted
        // the same way, so an unframed block still carries the verdict.
        return Group {
            if hasBody {
                stack.blockFrame(ramTint.opacity(0.85), fill: ramTint.darkened(0.48), radius: 8)
            } else {
                stack
            }
        }
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
    private var headline: String { reaper.struggleReason.uppercased() }

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
    /// The outline around a whole block, in the block's own colour, with its top edge running
    /// through the middle of the heading line.
    ///
    /// Nothing is cut out of the line: what breaks it is the heading's own chips, which are
    /// opaque and sit on top — the title at the left, the count at the right. That is why every
    /// item on that line wears a ground, and why the rule that used to sit *under* the heading
    /// is gone. One line through the name is a frame with a legend; two lines a few points apart
    /// is a mistake.
    ///
    /// Drawn outside the block's own bounds rather than padded into them, so hanging a frame on
    /// a column moves nothing inside it: the cards keep the width they had.
    /// `bottomSpread` pour les blocs qui gardent de la place en bas à l'intérieur — le fleet
    /// laisse 20pt sous la dernière rangée pour le halo au survol. Sans lui, ces 20pt
    /// s'ajoutent au débord et le noir descend deux fois plus bas sur le bas que sur les côtés.
    func blockFrame(_ tint: Color, fill: Color? = nil, spread: CGFloat = 13,
                    bottomSpread: CGFloat? = nil, headingCentre: CGFloat = 7,
                    radius: CGFloat = 12) -> some View {
        background(alignment: .top) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                // The same colour as the line, laid over the panel's black scrim — which
                // is what darkens it. A block is tinted, not coloured: the cards inside are
                // opaque and keep their own near-black, so this only ever shows in the margins.
                // Darkened rather than thinned: the hue is taken down towards black first,
                // so it stays its own colour. The sliver of transparency on top only lets
                // the desktop show through the margins.
                .fill((fill ?? tint.darkened(0.48)).opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(tint, lineWidth: 1)
                )
                .padding(.top, headingCentre)
                .padding(.horizontal, -spread)
                .padding(.bottom, -(bottomSpread ?? spread))
        }
    }

    /// Grey and half there, whatever the block: the colour is the block's own background now,
    /// and a chip in that same colour laid on top of it was a second statement of it. What a
    /// chip has to do is break the outline and stay readable, which a wash and an edge do.
    func titleGround() -> some View {
        padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                // Opaque first, wash second. The block's own colour starts at this line, and a
                // translucent chip let it through — the name sat on a coloured smear instead of
                // on the panel. The near-black is the one every card on the panel is drawn on.
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.12)))
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
    /// Black, alone among the five. The fleet is the thing this panel is for and the only
    /// block whose contents already carry colour — six session states, on every tile. A green
    /// frame around them put a seventh in the running.
    static let fleet = Color(white: 0.14)
    static let todo = Color(red: 0.13, green: 0.28, blue: 0.52)
    /// The two networks' own colours, dimmed to the panel's level: Instagram's pink and
    /// YouTube's red. Quiet, because neither block has anything to say most days — but their
    /// own, because a block is told apart by its colour everywhere else on this panel.
    static let reels = Color(red: 0.47, green: 0.12, blue: 0.31)
    static let youtube = Color(red: 0.47, green: 0.09, blue: 0.09)
}

/// One number and what it is, on the quiet strip.
/// A row whose children split the width by weight — the RAM pill two thirds, the swap pill
/// one — where an `HStack` hands any two flexible views half each. A lone child takes it all.
private struct WeightedRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let total = weights.prefix(subviews.count).reduce(0, +)
        let free = bounds.width - spacing * CGFloat(max(subviews.count - 1, 0))
        var x = bounds.minX
        for (i, view) in subviews.enumerated() {
            let width = free * weights[i] / total
            view.place(at: CGPoint(x: x, y: bounds.minY),
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

private struct Reading: View {
    let label: String
    let value: String
    /// A second, dimmer figure after the value — the share of the total, where there is one.
    var trailing: String?
    /// What the whole pill is worth saying in colour — the number and the ground under it.
    /// Nil on everything but the RAM share, which is the only one with a scale to be on.
    var accent: Color?
    /// Without its capsule. The RAM reading wears none: the whole memory block is its ground
    /// now, and it is the block that changes colour with the share.
    var bare = false
    init(_ label: String, _ value: String, trailing: String? = nil, accent: Color? = nil,
         bare: Bool = false) {
        self.label = label
        self.value = value
        self.trailing = trailing
        self.accent = accent
        self.bare = bare
    }

    var body: some View {
        // Space between, not around: the name sits on the left edge and the total on the
        // right, with the slack split between them. The figure lands in the middle because
        // the two gaps either side of it are the same, not because anything centres it.
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(accent ?? .white.opacity(0.95))
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, bare ? 2 : 10)
        // The same capsule the hog pills wear, for the same reason: on the panel's black these
        // numbers were text floating in a void, and a ground is what makes them a readout.
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background {
            if !bare {
                // Opaque, on the same near-black the mail and todo rows sit on. A translucent
                // pill over the scrim lets the desktop through, and a wallpaper is not a
                // background you can read a number off.
                Capsule().fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                    .overlay(Capsule().fill(accent?.opacity(0.22) ?? .white.opacity(0.05)))
                    .overlay(Capsule().stroke(accent?.opacity(0.55) ?? .white.opacity(0.14),
                                              lineWidth: 1))
            }
        }
    }
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
