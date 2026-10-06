import Cocoa
import SwiftUI
import Carbon
import UniformTypeIdentifiers

// MARK: - Models

enum ClipItemType: Codable {
    case text(String)
    case image(NSImage, URL?)
    case file(URL, String, Int64) // url, filename, fileSizeInBytes
    
    enum CodingKeys: String, CodingKey {
        case kind
        case textValue
        case imageRelativePath
        case fileRelativePath
        case filename
        case fileSize
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            let text = try container.decode(String.self, forKey: .textValue)
            self = .text(text)
        case "image":
            let rel = try container.decodeIfPresent(String.self, forKey: .imageRelativePath)
            if let rel = rel {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let fileURL = appSupport.appendingPathComponent("QuickClipStorage", isDirectory: true).appendingPathComponent(rel)
                if let img = NSImage(contentsOf: fileURL) {
                    self = .image(img, fileURL)
                } else {
                    self = .image(NSImage(), fileURL)
                }
            } else {
                self = .image(NSImage(), nil)
            }
        case "file":
            let rel = try container.decode(String.self, forKey: .fileRelativePath)
            let filename = try container.decode(String.self, forKey: .filename)
            let size = try container.decode(Int64.self, forKey: .fileSize)
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let fileURL = appSupport.appendingPathComponent("QuickClipStorage", isDirectory: true).appendingPathComponent(rel)
            self = .file(fileURL, filename, size)
        default:
            self = .text("")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let str):
            try container.encode("text", forKey: .kind)
            try container.encode(str, forKey: .textValue)
        case .image(_, let fileURL):
            try container.encode("image", forKey: .kind)
            try container.encodeIfPresent(fileURL?.lastPathComponent, forKey: .imageRelativePath)
        case .file(let url, let filename, let size):
            try container.encode("file", forKey: .kind)
            try container.encode(url.lastPathComponent, forKey: .fileRelativePath)
            try container.encode(filename, forKey: .filename)
            try container.encode(size, forKey: .fileSize)
        }
    }
}

final class ClipItem: Identifiable, ObservableObject, Codable {
    let id: UUID
    let timestamp: Date
    let type: ClipItemType
    @Published var isPinned: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case type
        case isPinned
    }
    
    init(id: UUID = UUID(), timestamp: Date = Date(), type: ClipItemType, isPinned: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.isPinned = isPinned
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.type = try container.decode(ClipItemType.self, forKey: .type)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(type, forKey: .type)
        try container.encode(isPinned, forKey: .isPinned)
    }
    
    var displayText: String {
        switch type {
        case .text(let str): return str
        case .image: return "Screenshot / Image"
        case .file(_, let filename, _): return filename
        }
    }
}

enum LayoutMode: String, CaseIterable {
    case vertical = "Vertical"
    case grid = "Grid"
}

enum TabFilter: String, CaseIterable {
    case recents = "Recents"
    case files = "Files"
    case pinned = "Pinned"
}

// MARK: - Clipboard & Storage Manager

final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()
    
    @Published var items: [ClipItem] = []
    @Published var alertMessage: String?
    
    private var lastChangeCount: Int = 0
    private var timer: Timer?
    private var storageDir: URL
    private var metadataURL: URL
    private let maxFileSize: Int64 = 5 * 1024 * 1024 // 5 MB maximum
    
    init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.storageDir = appSupport.appendingPathComponent("QuickClipStorage", isDirectory: true)
        self.metadataURL = storageDir.appendingPathComponent("quickclip_history.json")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        
        loadItems()
        startMonitoring()
    }
    
    func saveItems() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveItemsSync()
        }
    }
    
    func saveItemsSync() {
        let currentItems = self.items
        do {
            let data = try JSONEncoder().encode(currentItems)
            try data.write(to: self.metadataURL, options: .atomic)
        } catch {
            print("Failed to save QuickClip history: \(error)")
        }
    }
    
    private func loadItems() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }
        do {
            let data = try Data(contentsOf: metadataURL)
            let loaded = try JSONDecoder().decode([ClipItem].self, from: data)
            self.items = loaded
            sortItems()
        } catch {
            print("Failed to load QuickClip history: \(error)")
        }
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }
    
    func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        // 0. Privacy: Ignore sensitive/transient clips (1Password, Keychain, Bitwarden, KeePass)
        let sensitiveTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
            NSPasteboard.PasteboardType("com.agilebits.onepassword")
        ]
        if pasteboard.types?.contains(where: { sensitiveTypes.contains($0) }) == true {
            return
        }
        
        // 1. Check for Image / Screenshot (copied images/screenshots go to Recents)
        if let image = NSImage(pasteboard: pasteboard) {
            let fileURL = storageDir.appendingPathComponent("clip_\(UUID().uuidString.prefix(8)).png")
            DispatchQueue.global(qos: .utility).async {
                if let tiffData = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiffData),
                   let pngData = rep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: fileURL)
                }
            }
            
            DispatchQueue.main.async {
                self.items.insert(ClipItem(type: .image(image, fileURL)), at: 0)
                self.enforceItemLimit()
            }
            return
        }
        
        // 3. Check for Text (cap at 1MB to prevent memory exhaustion)
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            if string.count > 500_000 {
                return // Ignore excessively large text dumps
            }
            if let first = items.first, case .text(let prevText) = first.type, prevText == string {
                return
            }
            DispatchQueue.main.async {
                self.items.insert(ClipItem(type: .text(string)), at: 0)
                self.enforceItemLimit()
            }
        }
    }
    
    private func enforceItemLimit() {
        while self.items.count > 80 {
            if let last = self.items.last {
                self.deleteStoredAsset(for: last)
                self.items.removeLast()
            }
        }
        self.saveItems()
    }
    
    private func deleteStoredAsset(for item: ClipItem) {
        switch item.type {
        case .file(let url, _, _):
            try? FileManager.default.removeItem(at: url)
        case .image(_, let fileURL):
            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        case .text:
            break
        }
    }
    
    func addFile(from originalURL: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: originalURL.path, isDirectory: &isDir), !isDir.boolValue else {
            return
        }
        
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: originalURL.path),
              let size = attrs[.size] as? Int64 else { return }
        
        // File size limit: 5MB
        if size > maxFileSize {
            DispatchQueue.main.async {
                self.alertMessage = "File \"\(originalURL.lastPathComponent)\" exceeds 5 MB limit (\(String(format: "%.1f", Double(size)/1024.0/1024.0)) MB)."
            }
            return
        }
        
        // Unique filename to prevent accidental collision
        let uniquePrefix = UUID().uuidString.prefix(6)
        let destinationURL = storageDir.appendingPathComponent("\(uniquePrefix)_\(originalURL.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: originalURL, to: destinationURL)
            DispatchQueue.main.async {
                self.items.insert(ClipItem(type: .file(destinationURL, originalURL.lastPathComponent, size)), at: 0)
                self.enforceItemLimit()
            }
        } catch {
            print("Failed to store file: \(error)")
        }
    }
    
    func importFileViaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose lightweight documents or files (up to 5 MB)"
        panel.level = .floating
        
        // Show full standard Finder navigation (Sidebar, Recents, Downloads, Desktop)
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.resolvesAliases = true
        panel.showsHiddenFiles = false
        panel.canCreateDirectories = false
        
        // Bring app to front so panel shows complete standard macOS Open dialog
        NSApp.activate(ignoringOtherApps: true)
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                self.addFile(from: url)
            }
        }
    }
    
    func copyToClipboard(item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.type {
        case .text(let str):
            pb.setString(str, forType: .string)
        case .image(let img, _):
            pb.writeObjects([img])
        case .file(let url, _, _):
            pb.writeObjects([url as NSURL])
        }
        self.lastChangeCount = pb.changeCount
    }
    
    func togglePin(item: ClipItem) {
        objectWillChange.send()
        item.isPinned.toggle()
        sortItems()
        saveItems()
    }
    
    private func sortItems() {
        items.sort { $0.timestamp > $1.timestamp }
    }
    
    func removeItem(id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            deleteStoredAsset(for: item)
        }
        items.removeAll { $0.id == id }
        saveItems()
    }
    
    func removeSelectedItems(ids: Set<UUID>) {
        for id in ids {
            if let item = items.first(where: { $0.id == id }) {
                deleteStoredAsset(for: item)
            }
        }
        items.removeAll { ids.contains($0.id) }
        saveItems()
    }
    
    func clearAll() {
        for item in items {
            deleteStoredAsset(for: item)
        }
        items.removeAll()
        saveItems()
    }
}

// MARK: - Helper Formatters

func formatBytes(_ bytes: Int64) -> String {
    let kb = Double(bytes) / 1024.0
    if kb < 1024 {
        return String(format: "%.0f KB", kb)
    } else {
        return String(format: "%.1f MB", kb / 1024.0)
    }
}

// MARK: - SwiftUI Views

struct ClipCardView: View {
    @ObservedObject var item: ClipItem
    let isGrid: Bool
    let isSelectMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onCopy: () -> Void
    let onPinToggle: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var copiedFeedback: Bool = false
    
    @ViewBuilder
    private var cardHeader: some View {
        HStack(spacing: 4) {
            if isSelectMode {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
            }

            switch item.type {
            case .text:
                Image(systemName: "doc.text")
                    .foregroundColor(.blue)
                    .font(.caption2)
                Text("Text")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            case .image:
                Image(systemName: "photo")
                    .foregroundColor(.green)
                    .font(.caption2)
                Text("Image")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            case .file(_, let filename, let size):
                let isPdf = filename.lowercased().hasSuffix(".pdf")
                Image(systemName: isPdf ? "doc.richtext.fill" : "doc.fill")
                    .foregroundColor(isPdf ? .red : .purple)
                    .font(.caption2)
                Text(formatBytes(size))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
                    .foregroundColor(.secondary)
            }
            
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
            
            Spacer()
            
            if !isSelectMode {
                HStack(spacing: 6) {
                    Button(action: onPinToggle) {
                        Image(systemName: item.isPinned ? "pin.slash.fill" : "pin")
                            .font(.system(size: 11))
                            .foregroundColor(item.isPinned ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "Unpin item" : "Pin to top")
                    
                    Button(action: {
                        onCopy()
                        withAnimation { copiedFeedback = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation { copiedFeedback = false }
                        }
                    }) {
                        Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(copiedFeedback ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .opacity(isHovered || item.isPinned ? 1.0 : 0.0)
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        switch item.type {
        case .text(let str):
            Text(str)
                .font(.system(size: 12))
                .lineLimit(isGrid ? 5 : 4)
                .multilineTextAlignment(.leading)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
        case .image(let nsImage, _):
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: isGrid ? 80 : 120)
                .cornerRadius(6)
                .frame(maxWidth: .infinity)
            
        case .file(let url, let filename, _):
            HStack(spacing: 8) {
                Image(systemName: filename.lowercased().hasSuffix(".pdf") ? "doc.richtext.fill" : "doc.badge.arrow.up")
                    .font(.system(size: isGrid ? 22 : 26))
                    .foregroundColor(filename.lowercased().hasSuffix(".pdf") ? .red : .purple)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(isGrid ? 2 : 1)
                        .foregroundColor(.primary)
                    
                    Text("Drag to export • Click to open")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectMode {
                    onToggleSelect()
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private var cardFillColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        } else if isHovered {
            return Color(NSColor.controlBackgroundColor).opacity(0.85)
        } else {
            return Color(NSColor.windowBackgroundColor).opacity(0.5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Subtle, sleek Pin Bar if item is pinned
            if item.isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text("PINNED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.bottom, 2)
            }
            
            cardHeader
            cardContent
        }
        .padding(10)
        .frame(minHeight: isGrid ? 110 : nil)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleSelect()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onDrag {
            guard !isSelectMode else { return NSItemProvider() }
            switch item.type {
            case .text(let str):
                let provider = NSItemProvider()
                // Register as both plain text and NSString for maximum app compatibility (Slack, Discord, Chrome, Terminal, etc.)
                provider.registerObject(str as NSString, visibility: .all)
                if let data = str.data(using: .utf8) {
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                        completion(data, nil)
                        return nil
                    }
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
                        completion(data, nil)
                        return nil
                    }
                }
                return provider
            case .image(let nsImage, let fileURL):
                let provider = NSItemProvider()
                if let url = fileURL {
                    provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: .openInPlace, visibility: .all) { completion in
                        completion(url, true, nil)
                        return nil
                    }
                }
                provider.registerObject(nsImage, visibility: .all)
                return provider
            case .file(let url, _, _):
                let provider = NSItemProvider()
                provider.registerFileRepresentation(forTypeIdentifier: UTType.item.identifier, fileOptions: .openInPlace, visibility: .all) { completion in
                    completion(url, true, nil)
                    return nil
                }
                return provider
            }
        }
    }
}

// Window Drag Handle bar for moving the floating window
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        return DragView()
    }
    func updateNSView(_ nsView: DragView, context: Context) {}
    
    class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct ContentView: View {
    @ObservedObject var clipboard = ClipboardManager.shared
    @State private var searchText: String = ""
    @State private var layoutMode: LayoutMode = .vertical
    @State private var selectedTab: TabFilter = .recents
    @State private var isTargetedForDrop: Bool = false
    
    // Select / Multi-Select Mode
    @State private var isSelectMode: Bool = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var showClearConfirmation: Bool = false
    
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    
    var filteredItems: [ClipItem] {
        let baseItems: [ClipItem]
        switch selectedTab {
        case .recents:
            baseItems = clipboard.items.filter { item in
                if item.isPinned { return false }
                if case .file = item.type { return false }
                return true
            }
        case .files:
            baseItems = clipboard.items.filter {
                if case .file = $0.type { return true }
                return false
            }
        case .pinned:
            baseItems = clipboard.items.filter { $0.isPinned }
        }
        
        if searchText.isEmpty {
            return baseItems
        } else {
            return baseItems.filter { item in
                switch item.type {
                case .text(let str):
                    return str.localizedCaseInsensitiveContains(searchText)
                case .image:
                    return "screenshot image photo".localizedCaseInsensitiveContains(searchText)
                case .file(_, let filename, _):
                    return filename.localizedCaseInsensitiveContains(searchText)
                }
            }
        }
    }
    
    @ViewBuilder
    private var topHeaderBar: some View {
        HStack(spacing: 8) {
            // Window control buttons (Close: Red, Minimize: Green)
            HStack(spacing: 6) {
                Button(action: { onClose() }) {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: .systemRed).opacity(0.85))
                            .frame(width: 13, height: 13)
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .help("Close")

                Button(action: { onMinimize() }) {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: .systemGreen).opacity(0.85))
                            .frame(width: 13, height: 13)
                        Image(systemName: "minus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .help("Minimize / Hide (⌥+Space)")
            }
            .padding(.trailing, 2)

            Text("QuickClip")
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
            
            HStack(spacing: 2) {
                Button(action: { layoutMode = .vertical }) {
                    Image(systemName: "rectangle.grid.1x2.fill")
                        .font(.system(size: 11))
                        .padding(4)
                        .background(layoutMode == .vertical ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(layoutMode == .vertical ? .accentColor : .secondary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Vertical List View")
                
                Button(action: { layoutMode = .grid }) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11))
                        .padding(4)
                        .background(layoutMode == .grid ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(layoutMode == .grid ? .accentColor : .secondary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Grid View")
            }
            .padding(2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
            
            Text("⌥+Space")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var tabsBar: some View {
        HStack(spacing: 6) {
            ForEach(TabFilter.allCases, id: \.self) { tab in
                let count: Int = {
                    switch tab {
                    case .recents: return clipboard.items.filter { item in
                        if item.isPinned { return false }
                        if case .file = item.type { return false }
                        return true
                    }.count
                    case .files: return clipboard.items.filter {
                        if case .file = $0.type { return true }
                        return false
                    }.count
                    case .pinned: return clipboard.items.filter { $0.isPinned }.count
                    }
                }()
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 3) {
                        if tab == .pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundColor(selectedTab == tab ? .orange : .secondary)
                        } else if tab == .files {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 8))
                                .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        }
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                        Text("(\(count))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        selectedTab == tab
                            ? Color.accentColor.opacity(0.18)
                            : Color.secondary.opacity(0.08)
                    )
                    .cornerRadius(6)
                    .foregroundColor(selectedTab == tab ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var selectionActionBar: some View {
        if isSelectMode {
            HStack(spacing: 12) {
                Button(action: {
                    let currentIDs = Set(filteredItems.map { $0.id })
                    if selectedItemIDs.isSuperset(of: currentIDs) {
                        selectedItemIDs.subtract(currentIDs)
                    } else {
                        selectedItemIDs.formUnion(currentIDs)
                    }
                }) {
                    let allSelected = !filteredItems.isEmpty && selectedItemIDs.isSuperset(of: Set(filteredItems.map { $0.id }))
                    HStack(spacing: 4) {
                        Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                        Text(allSelected ? "Deselect All" : "Select All")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                
                Text("\(selectedItemIDs.count) selected")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if !selectedItemIDs.isEmpty {
                    Button(action: {
                        showClearConfirmation = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Clear (\(selectedItemIDs.count))")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSelectMode = false
                        selectedItemIDs.removeAll()
                    }
                }) {
                    Text("Done")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    @ViewBuilder
    private var searchInputBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search \(selectedTab.rawValue.lowercased()) items...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(7)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var clipsContentList: some View {
        if filteredItems.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                if selectedTab == .files {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 38))
                            .foregroundColor(.accentColor.opacity(0.7))
                        Text("No files saved yet")
                            .font(.headline)
                        Text("Drag & drop any PDF or document here\nor browse from your Mac (up to 5MB).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: { clipboard.importFileViaPicker() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                Text("Browse & Add File")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.accentColor)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                } else if selectedTab == .pinned {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No pinned items.\nClick 📌 on any card to pin it here!")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(clipboard.items.isEmpty ? "No recent clips.\nCopy text or screenshots anywhere!" : "No matches found.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if selectedTab == .files && !isSelectMode {
                    Button(action: { clipboard.importFileViaPicker() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                                .font(.system(size: 14))
                            Text("Add Document / PDF (up to 5MB)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.accentColor)
                            Spacer()
                            Text("Browse")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4]))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }
                
                if layoutMode == .vertical {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            ClipCardView(
                                item: item,
                                isGrid: false,
                                isSelectMode: isSelectMode,
                                isSelected: selectedItemIDs.contains(item.id),
                                onToggleSelect: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if !isSelectMode {
                                            isSelectMode = true
                                            selectedItemIDs = [item.id]
                                        } else {
                                            if selectedItemIDs.contains(item.id) {
                                                selectedItemIDs.remove(item.id)
                                                if selectedItemIDs.isEmpty {
                                                    isSelectMode = false
                                                }
                                            } else {
                                                selectedItemIDs.insert(item.id)
                                            }
                                        }
                                    }
                                },
                                onCopy: { clipboard.copyToClipboard(item: item) },
                                onPinToggle: { clipboard.togglePin(item: item) },
                                onDelete: { clipboard.removeItem(id: item.id) }
                            )
                        }
                    }
                    .padding(14)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(filteredItems) { item in
                            ClipCardView(
                                item: item,
                                isGrid: true,
                                isSelectMode: isSelectMode,
                                isSelected: selectedItemIDs.contains(item.id),
                                onToggleSelect: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if !isSelectMode {
                                            isSelectMode = true
                                            selectedItemIDs = [item.id]
                                        } else {
                                            if selectedItemIDs.contains(item.id) {
                                                selectedItemIDs.remove(item.id)
                                                if selectedItemIDs.isEmpty {
                                                    isSelectMode = false
                                                }
                                            } else {
                                                selectedItemIDs.insert(item.id)
                                            }
                                        }
                                    }
                                },
                                onCopy: { clipboard.copyToClipboard(item: item) },
                                onPinToggle: { clipboard.togglePin(item: item) },
                                onDelete: { clipboard.removeItem(id: item.id) }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topHeaderBar
            tabsBar
            selectionActionBar
            searchInputBar
            
            if let alert = clipboard.alertMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                    Text(alert)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: { clipboard.alertMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.15))
                .cornerRadius(6)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
            
            Divider()
            clipsContentList
            Divider()
            
            // Footer with contextual hints
            HStack {
                if selectedTab == .files {
                    Text("📁 Drop files here to stash (up to 5MB) • ⌥+Space")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("📋 Drag clips out to paste • ⌥+Space")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
            .background(WindowDragHandle())
        }
        .frame(width: 390, height: 520)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isTargetedForDrop && selectedTab == .files ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isTargetedForDrop && selectedTab == .files ? 2 : 1)
        )
        // Accept incoming dragged files from Finder only when on Files tab
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard selectedTab == .files else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            clipboard.addFile(from: url)
                        }
                    }
                }
            }
            return true
        }
        .alert(isPresented: $showClearConfirmation) {
            Alert(
                title: Text("Clear Selected Items"),
                message: Text("Your paste data will be erased. Continue?"),
                primaryButton: .destructive(Text("Continue")) {
                    clipboard.removeSelectedItems(ids: selectedItemIDs)
                    selectedItemIDs.removeAll()
                    isSelectMode = false
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }
}

// Visual Effect View for clean frosted glass background
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Floating Window & Hotkey Management

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: flag ? .buffered : backing,
            defer: flag
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        // Set isMovableByWindowBackground to false so item dragging won't drag the whole window!
        self.isMovableByWindowBackground = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
    }
    
    override var canBecomeKey: Bool {
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    var statusItem: NSStatusItem?
    var hotKeyRef: EventHotKeyRef?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPanel()
        setupMenuBar()
        setupGlobalHotkey()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        ClipboardManager.shared.saveItemsSync()
    }
    
    func setupPanel() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 800, height: 600)
        let panelWidth: CGFloat = 390
        let panelHeight: CGFloat = 520
        let origin = NSPoint(x: screenRect.maxX - panelWidth - 20, y: screenRect.maxY - panelHeight - 20)
        
        panel = FloatingPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)),
            backing: .buffered,
            defer: false
        )
        
        let contentView = ContentView(
            onClose: { [weak self] in
                self?.panel?.orderOut(nil)
            },
            onMinimize: { [weak self] in
                self?.panel?.orderOut(nil)
            }
        )
        panel?.contentView = NSHostingView(rootView: contentView)
        panel?.makeKeyAndOrderFront(nil)
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "QuickClip")
            button.target = self
            button.action = #selector(togglePanel)
        }
    }
    
    @objc func togglePanel() {
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    // Carbon Global Hotkey (Option + Space: ⌥ + Space)
    func setupGlobalHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x51434C50) // "QCLP"
        hotKeyID.id = 1
        
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, theEvent, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.togglePanel()
            }
            return noErr
        }, 1, &eventType, selfPointer, nil)
        
        RegisterEventHotKey(49, UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
