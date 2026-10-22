import SwiftUI

/// A block Fleet draws without knowing what it is about. Any program writes
/// `~/.local/state/fleet/blocks/<name>.json` and the block is under SPENDING at the next open:
/// what gathers the data runs on its own, and one that dies leaves its last file standing
/// rather than taking Fleet down with it. Asked for on 2026-10-20, Fleet doing too much on
/// this Mac: the blocks were to be plugins.
struct PluginBlock: Decodable, Identifiable {
    /// The file's name, which orders the blocks.
    var id = ""
    let title: String
    /// `#RRGGBB`.
    var tint: String?
    /// `faces`: three to a line, a picture over a name. Anything else: a line each, the text
    /// at the left and its detail at the right.
    var layout: String?
    var groups: [Group]

    struct Group: Decodable {
        var title: String?
        let items: [Item]
    }

    struct Item: Decodable, Equatable {
        let text: String
        var detail: String?
        /// A path from the blocks folder.
        var image: String?
        /// Under the pointer.
        var help: String?
    }

    private enum CodingKeys: String, CodingKey { case title, tint, layout, groups }

    var color: Color {
        let hex = tint.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        guard let value = hex.flatMap({ UInt32($0, radix: 16) }) else { return Color(white: 0.4) }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

/// The folder, read again when a file in it has been written, added or taken away, and not
/// before — see `MoneyStore`.
@MainActor
final class PluginStore: ObservableObject {
    static let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/state/fleet/blocks")

    @Published private(set) var blocks: [PluginBlock] = []
    /// By the path the file gives. Read with the files and only then: a picture added on its
    /// own shows once its file is written again.
    private(set) var pictures: [String: NSImage] = [:]

    /// Pointed elsewhere by a picture meant to be published — see `DemoFleet.fill`.
    var folder = PluginStore.folder { didSet { written = nil; rereadIfWritten() } }
    private var written: [String: Date]?

    init() { rereadIfWritten() }

    func rereadIfWritten() {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let dates = Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent,
             (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        })
        guard dates != written else { return }
        written = dates
        let read = files.compactMap { file -> PluginBlock? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return Self.decode(data, id: file.lastPathComponent)
        }
        let paths = Set(read.flatMap { $0.groups.flatMap { $0.items.compactMap(\.image) } })
        pictures = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            NSImage(contentsOf: folder.appending(path: path)).map { (path, $0) }
        })
        blocks = read
    }

    /// A block with nothing in it is not drawn. Its empty groups are kept: they are where a
    /// carried item can be put down — see `PluginColumn.shown`.
    static func decode(_ data: Data, id: String) -> PluginBlock? {
        do {
            var block = try JSONDecoder().decode(PluginBlock.self, from: data)
            block.id = id
            return block.groups.allSatisfy(\.items.isEmpty) ? nil : block
        } catch {
            // Once per write: the folder is not read again until a file in it changes.
            NSLog("Fleet: block \(id) not drawn — \(error)")
            return nil
        }
    }

    /// An item, by its block, its group's place in the file and what it says.
    struct Spot: Equatable {
        let block: String
        let group: Int
        let item: PluginBlock.Item
    }

    /// The item under the pointer, which ⌘⌫ takes out.
    var hovered: Spot?

    /// ⌘⌫: whether there was an item under the pointer to take out. When there was not, the key
    /// goes on to the prompt field.
    func removeHovered() -> Bool {
        guard let hovered else { return false }
        self.hovered = nil
        rewrite(hovered, to: nil)
        return true
    }

    /// The block's file written again, the item taken out of its group and put at the end of
    /// `target` when there is one. Every key in the file is kept, Fleet's or not. The item is
    /// found by what it says in the file as it is now, so one its program has rewritten since
    /// is left alone.
    func rewrite(_ spot: Spot, to target: Int?) {
        let file = folder.appending(path: spot.block)
        guard let data = try? Data(contentsOf: file),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var groups = root["groups"] as? [[String: Any]],
              groups.indices.contains(spot.group), target.map(groups.indices.contains) ?? true,
              var items = groups[spot.group]["items"] as? [[String: Any]],
              let index = items.firstIndex(where: { Self.item($0) == spot.item }) else { return }
        let item = items.remove(at: index)
        groups[spot.group]["items"] = items
        if let target {
            var into = groups[target]["items"] as? [Any] ?? []
            into.append(item)
            groups[target]["items"] = into
        }
        root["groups"] = groups
        do {
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: file, options: .atomic)
        } catch {
            NSLog("Fleet: block \(spot.block) not written — \(error)")
            return
        }
        rereadIfWritten()
    }

    private static func item(_ object: [String: Any]) -> PluginBlock.Item? {
        (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { try? JSONDecoder().decode(PluginBlock.Item.self, from: $0) }
    }
}

/// Every block of the folder, one under the other.
struct PluginColumns: View {
    @ObservedObject var store: PluginStore
    var commandHeld = false
    /// Off for a render that draws no scroll view — see `CronColumn`.
    var scrolling = true
    /// The most each block takes of its column, past which its list scrolls.
    var limit: CGFloat = .infinity

    var body: some View {
        ForEach(store.blocks) { block in
            PluginColumn(block: block, store: store, commandHeld: commandHeld,
                         scrolling: scrolling, limit: limit)
        }
    }
}

/// Folded to its heading and the count at rest, as SPENDING is, and unfolded by the pointer:
/// what a block lists is not for whoever stands behind the screen.
///
/// ⌘ held, an item follows the pointer from a press and lands in the group it is let go over,
/// and ⌘⌫ takes out the one under the pointer (asked for on 2026-10-22). Either way Fleet writes
/// the file, which is otherwise its program's to write.
struct PluginColumn: View {
    let block: PluginBlock
    let store: PluginStore
    var commandHeld = false
    var scrolling = true
    var limit: CGFloat = .infinity

    @State private var open = CommandLine.arguments.contains("--blocks-open")
    /// Whether the lower edge cuts a line.
    @State private var runsOn = false
    /// The item in the pointer's hand. Gone with the gesture, however it ends.
    @GestureState private var carried: Carried?
    /// Each group's frame in the list: the one under the pointer is where a carried item lands.
    @State private var frames: [Int: CGRect] = [:]

    private struct Carried: Equatable {
        let group: Int
        /// Its place in the group, which tells apart two items that say the same.
        let index: Int
        let item: PluginBlock.Item
        /// The pointer, in the list's space.
        var at: CGPoint
    }

    /// The heading, the gap under it and the frame's own padding.
    private static let chrome: CGFloat = 56
    private static let space = "plugin-list"

    /// ⌘ over the open block: its items can be picked up.
    private var armed: Bool { commandHeld && open }

    /// The groups drawn, by their place in the file: the empty ones too while an item can be
    /// carried, as somewhere to put it down.
    private var shown: [Int] {
        block.groups.indices.filter { armed || carried != nil || !block.groups[$0].items.isEmpty }
    }

    var body: some View {
        let room = max(40, limit - Self.chrome)
        HubColumn(title: block.title.uppercased(),
                  count: block.groups.reduce(0) { $0 + $1.items.count },
                  tint: block.color,
                  fill: block.color.darkened(0.48),
                  topInset: 5,
                  collapsed: !open && carried == nil) {
            if scrolling {
                list(live: false).hidden()
                    .frame(maxHeight: room, alignment: .top)
                    .overlay {
                        ScrollView(.vertical) { list(live: true) }
                            .scrollIndicators(.hidden)
                            .scrollBounceBehavior(.basedOnSize)
                            // The cut fades out, as SPENDING's does, so it reads as more below.
                            .onScrollGeometryChange(for: Bool.self) {
                                $0.contentOffset.y + $0.containerSize.height < $0.contentSize.height - 1
                            } action: { _, cut in runsOn = cut }
                            .mask {
                                VStack(spacing: 0) {
                                    Rectangle()
                                    if runsOn {
                                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                            .frame(height: 36)
                                    }
                                }
                            }
                    }
            } else {
                list(live: true).frame(maxHeight: room, alignment: .top).clipped()
            }
        }
        .onHover { inside in
            withAnimation(OverlayView.fold) { open = inside }
            if !inside, store.hovered?.block == block.id { store.hovered = nil }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `live` is the copy on screen; the hidden one only gives the block its height, and takes
    /// no pointer.
    private func list(live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element) { position, index in
                let group = block.groups[index]
                if position > 0 { rule }
                VStack(alignment: .leading, spacing: 3) {
                    if let title = group.title {
                        Text(title.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(block.color.lightened(0.65))
                    }
                    if group.items.isEmpty {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(height: 30)
                            .padding(.top, 4)
                    } else if block.layout == "faces" {
                        // Three to a line, the picture over the name.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                                  spacing: 8) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { slot, item in
                                carriable(VStack(spacing: 4) {
                                    face(item)
                                    Text(item.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(1)
                                }
                                .help(item.help ?? ""), group: index, slot: slot, item: item, live: live)
                            }
                        }
                        .padding(.top, 4)
                    } else {
                        ForEach(Array(group.items.enumerated()), id: \.offset) { slot, item in
                            carriable(HStack(spacing: 8) {
                                Text(item.text)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let detail = item.detail {
                                    Text(detail)
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                }
                            }
                            .font(.system(size: 11))
                            .help(item.help ?? ""), group: index, slot: slot, item: item, live: live)
                        }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                    if live { frames[index] = $0 }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) {
            if live, let carried {
                Group {
                    if block.layout == "faces" {
                        face(carried.item)
                    } else {
                        Text(carried.item.text).font(.system(size: 11)).foregroundStyle(.white)
                    }
                }
                .scaleEffect(1.15)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                .position(carried.at)
                .allowsHitTesting(false)
            }
        }
    }

    /// What lets ⌘ pick an item up and ⌘⌫ find it, on the copy on screen only.
    @ViewBuilder
    private func carriable(_ view: some View, group: Int, slot: Int, item: PluginBlock.Item,
                           live: Bool) -> some View {
        if live {
            let spot = PluginStore.Spot(block: block.id, group: group, item: item)
            view
                .opacity(carried?.group == group && carried?.index == slot ? 0.3 : 1)
                .onHover { inside in
                    if inside { store.hovered = spot } else if store.hovered == spot { store.hovered = nil }
                }
                // From the press, not past a distance: a ⌘-click that has not moved yet would
                // otherwise go through to the panel's tap, which puts it away. Still held when
                // ⌘ is let go mid-way, so the drop is the mouse's to make.
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .updating($carried) { value, state, _ in
                        state = Carried(group: group, index: slot, item: item, at: value.location)
                    }
                    .onEnded { value in drop(spot, at: value.location) },
                         including: armed || carried != nil ? .all : .subviews)
        } else {
            view
        }
    }

    /// Let go over another group: the item goes to the end of it. Anywhere else it goes back.
    private func drop(_ spot: PluginStore.Spot, at point: CGPoint) {
        // Widened by half the gap between two groups, so a drop on the rule still lands.
        // Every group is drawn while one is carried, so no frame here is a stale one.
        guard let target = frames.first(where: { $0.value.insetBy(dx: -8, dy: -10).contains(point) })?.key,
              target != spot.group else { return }
        store.rewrite(spot, to: target)
    }

    /// The picture in a circle, or the initial where there is none.
    private func face(_ item: PluginBlock.Item) -> some View {
        Group {
            if let picture = item.image.flatMap({ store.pictures[$0] }) {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                Text(item.text.prefix(1))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(block.color.opacity(0.5))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
    }

    /// CRONS's rule between its families: a frame round a group is a block inside a block.
    private var rule: some View {
        Rectangle()
            .fill(.white.opacity(0.6))
            .frame(height: 1)
            .scaleEffect(x: 0.85)
            .padding(.vertical, 3)
    }
}
