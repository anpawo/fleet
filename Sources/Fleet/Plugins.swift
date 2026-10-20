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

    struct Item: Decodable {
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

    /// A group with nothing in it is left out, and a block with nothing in it is not drawn.
    static func decode(_ data: Data, id: String) -> PluginBlock? {
        do {
            var block = try JSONDecoder().decode(PluginBlock.self, from: data)
            block.id = id
            block.groups = block.groups.filter { !$0.items.isEmpty }
            return block.groups.isEmpty ? nil : block
        } catch {
            // Once per write: the folder is not read again until a file in it changes.
            NSLog("Fleet: block \(id) not drawn — \(error)")
            return nil
        }
    }
}

/// Every block of the folder, one under the other.
struct PluginColumns: View {
    @ObservedObject var store: PluginStore
    /// Off for a render that draws no scroll view — see `CronColumn`.
    var scrolling = true
    /// The most each block takes of its column, past which its list scrolls.
    var limit: CGFloat = .infinity

    var body: some View {
        ForEach(store.blocks) { block in
            PluginColumn(block: block, pictures: store.pictures, scrolling: scrolling, limit: limit)
        }
    }
}

/// Folded to its heading and the count at rest, as SPENDING is, and unfolded by the pointer:
/// what a block lists is not for whoever stands behind the screen.
struct PluginColumn: View {
    let block: PluginBlock
    let pictures: [String: NSImage]
    var scrolling = true
    var limit: CGFloat = .infinity

    @State private var open = CommandLine.arguments.contains("--blocks-open")
    /// Whether the lower edge cuts a line.
    @State private var runsOn = false

    /// The heading, the gap under it and the frame's own padding.
    private static let chrome: CGFloat = 56

    var body: some View {
        let room = max(40, limit - Self.chrome)
        HubColumn(title: block.title.uppercased(),
                  count: block.groups.reduce(0) { $0 + $1.items.count },
                  tint: block.color,
                  topInset: 5,
                  collapsed: !open) {
            if scrolling {
                list.hidden()
                    .frame(maxHeight: room, alignment: .top)
                    .overlay {
                        ScrollView(.vertical) { list }
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
                list.frame(maxHeight: room, alignment: .top).clipped()
            }
        }
        .onHover { inside in withAnimation(OverlayView.fold) { open = inside } }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(block.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { rule }
                VStack(alignment: .leading, spacing: 3) {
                    if let title = group.title {
                        Text(title.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(block.color.bright.darkened(0.6))
                    }
                    if block.layout == "faces" {
                        // Three to a line, the picture over the name.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                                  spacing: 8) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                VStack(spacing: 4) {
                                    face(item)
                                    Text(item.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Site.ink)
                                        .lineLimit(1)
                                }
                                .help(item.help ?? "")
                            }
                        }
                        .padding(.top, 4)
                    } else {
                        ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 8) {
                                Text(item.text)
                                    .foregroundStyle(Site.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let detail = item.detail {
                                    Text(detail)
                                        .foregroundStyle(Site.ink.opacity(0.7))
                                        .lineLimit(1)
                                }
                            }
                            .font(.system(size: 11))
                            .help(item.help ?? "")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    /// The picture in a circle, or the initial where there is none.
    private func face(_ item: PluginBlock.Item) -> some View {
        Group {
            if let picture = item.image.flatMap({ pictures[$0] }) {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                Text(item.text.prefix(1))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(block.color.opacity(0.5))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .overlay(Circle().stroke(Site.line, lineWidth: 1))
    }

    /// CRONS's rule between its families: a frame round a group is a block inside a block.
    private var rule: some View {
        Rectangle()
            .fill(Site.line)
            .frame(height: 1)
            .scaleEffect(x: 0.85)
            .padding(.vertical, 3)
    }
}
