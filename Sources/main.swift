import Cocoa
import Carbon.HIToolbox
import SwiftUI

// clipdeck — free Paste-style clipboard manager.
// Menubar agent + bottom shelf of history cards on ⌘⇧V.

// MARK: - Store

struct Clip: Identifiable {
    let id = UUID()
    let date = Date()
    let kind: Kind
    enum Kind { case text(String), image(Data), file([String]) }
    var pinned = false
    var appIcon: NSImage?
    var appName: String = ""

    var preview: String {
        switch kind {
        case .text(let s):  return String(s.prefix(400))
        case .image:        return "Image"
        case .file(let f):  return f.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }
    var image: NSImage? {
        if case .image(let d) = kind { return NSImage(data: d) }
        return nil
    }
    var typeLabel: String {
        switch kind {
        case .text:  return "TEXT"
        case .image: return "IMAGE"
        case .file:  return "FILE"
        }
    }
    var accent: Color {
        switch kind {
        case .text:  return .blue
        case .image: return .green
        case .file:  return .orange
        }
    }
    func write(to pb: NSPasteboard) {
        pb.clearContents()
        switch kind {
        case .text(let s):  pb.setString(s, forType: .string)
        case .image(let d):
            pb.setData(d, forType: .tiff)
            if let img = NSImage(data: d), let png = img.pngData { pb.setData(png, forType: .png) }
        case .file(let paths):
            pb.writeObjects(paths.map { NSURL(fileURLWithPath: $0) } as [NSPasteboardWriting])
        }
    }
    /// Plain-text version of this clip (RTF / file paths flattened).
    func writePlain(to pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(preview, forType: .string)
    }
}

final class Store: ObservableObject {
    static let shared = Store()
    @Published private(set) var items: [Clip] = []
    @Published var query = ""
    var capacity = 200
    private var ignoredApps = Set<String>()
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    var filtered: [Clip] {
        let q = query.lowercased()
        let base = items.filter { q.isEmpty || $0.preview.lowercased().contains(q) }
        return base.sorted { ($0.pinned ? 0 : 1, -$0.date.timeIntervalSince1970)
                           < ($1.pinned ? 0 : 1, -$1.date.timeIntervalSince1970) }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in self.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let front = NSWorkspace.shared.frontmostApplication
        if let bid = front?.bundleIdentifier, ignoredApps.contains(bid) { return }
        var clip: Clip?
        if let s = pb.string(forType: .string), !s.isEmpty {
            clip = Clip(kind: .text(s))
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            clip = Clip(kind: .file(urls.map(\.path)))
        } else if let d = pb.data(forType: .tiff) {
            clip = Clip(kind: .image(d))
        }
        guard var c = clip else { return }
        c.appIcon = front?.icon
        c.appName = front?.localizedName ?? ""
        if let i = items.firstIndex(where: { $0.preview == c.preview }) { items.remove(at: i) }
        items.insert(c, at: 0)
        let unpinned = items.filter { !$0.pinned }
        if unpinned.count > capacity, let last = unpinned.last,
           let idx = items.firstIndex(where: { $0.id == last.id }) {
            items.remove(at: idx)
        }
    }

    func pin(_ c: Clip) {
        if let i = items.firstIndex(where: { $0.id == c.id }) { items[i].pinned.toggle() }
    }
    func delete(_ c: Clip) { items.removeAll { $0.id == c.id } }
    func clearUnpinned() { items.removeAll { !$0.pinned } }

    func paste(_ c: Clip, plain: Bool = false) {
        if plain { c.writePlain(to: .general) } else { c.write(to: .general) }
        lastChange = NSPasteboard.general.changeCount
        Shelf.shared.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

extension NSImage {
    var pngData: Data? {
        tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
    }
}

// MARK: - Shelf window

final class Shelf: NSWindow {
    static let shared = Shelf()
    private var keyMon: Any?
    var prevApp: NSRunningApplication?
    @Published var selected = 0
    var shown = false

    private init() {
        super.init(contentRect: .zero,
                   styleMask: [.titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        isOpaque = false; backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        contentView = NSHostingView(rootView: ShelfView())
    }

    func toggle() { shown ? hide() : show() }

    func show() {
        guard let s = NSScreen.main else { return }
        selected = 0
        contentView = NSHostingView(rootView: ShelfView())
        let h: CGFloat = 360
        setFrame(CGRect(x: s.frame.minX, y: s.frame.minY,
                        width: s.frame.width, height: h), display: true)
        alphaValue = 0
        orderFrontRegardless()
        shown = true
        FileHandle.standardError.write("clipdeck: shelf shown at \(frame)\n".data(using: .utf8)!)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        // focus the search field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let tf = self.contentView?.firstDescendant(of: NSTextField.self) {
                self.makeFirstResponder(tf)
            }
        }
        keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 53:  Shelf.shared.hide(); return nil                    // ⎋
            case 36:  Shelf.shared.pasteSelected(); return nil           // ⏎
            case 51:  Shelf.shared.deleteSelected(); return nil          // ⌫
            case 123: Shelf.shared.moveSel(-1); return nil               // ←
            case 124: Shelf.shared.moveSel(1); return nil                // →
            default: break
            }
            if e.modifierFlags.contains(.command), let n = Int(e.characters ?? ""),
               (1...9).contains(n) {
                Shelf.shared.pasteIndex(n - 1); return nil
            }
            return e
        }
    }

    func hide() {
        shown = false
        if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        Store.shared.query = ""
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
            if let app = self.prevApp { app.activate(options: .activateIgnoringOtherApps) }
        }
    }

    func moveSel(_ d: Int) {
        let n = Store.shared.filtered.count
        if n > 0 { selected = (selected + d + n) % n; refresh() }
    }
    func pasteSelected() {
        let f = Store.shared.filtered
        if selected < f.count { Store.shared.paste(f[selected]) }
    }
    func pasteIndex(_ i: Int) {
        let f = Store.shared.filtered
        if i < f.count { Store.shared.paste(f[i]) }
    }
    func deleteSelected() {
        let f = Store.shared.filtered
        if selected < f.count { Store.shared.delete(f[selected]); refresh() }
    }
    func refresh() {
        contentView = NSHostingView(rootView: ShelfView())
    }
    func refreshSoon() {
        DispatchQueue.main.async { self.refresh() }
    }
}

// MARK: - SwiftUI UI

struct ShelfView: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        VStack(spacing: 0) {
            // header: search + count
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 17, weight: .semibold))
                    Text("clipdeck").font(.system(size: 15, weight: .bold))
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search clipboard…", text: $store.query)
                        .textFieldStyle(.plain).font(.system(size: 15))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary))
                Text("\(store.items.count) items")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 12)

            if store.filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "clipboard").font(.system(size: 42))
                        .foregroundStyle(.tertiary)
                    Text(store.query.isEmpty ? "Copy something — it lands here"
                                             : "No matches for “\(store.query)”")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(Array(store.filtered.prefix(60).enumerated()),
                                    id: \.element.id) { i, c in
                                CardView(clip: c, index: i,
                                         selected: i == Shelf.shared.selected)
                                    .id(c.id)
                                    .onTapGesture {
                                        Shelf.shared.selected = i
                                        Shelf.shared.pasteSelected()
                                    }
                                    .contextMenu {
                                        Button(c.pinned ? "Unpin" : "Pin to top") {
                                            store.pin(c); Shelf.shared.refreshSoon()
                                        }
                                        Button("Paste as plain text") { store.paste(c, plain: true) }
                                        Divider()
                                        Button("Delete") { store.delete(c); Shelf.shared.refreshSoon() }
                                    }
                            }
                        }
                        .padding(.horizontal, 26).padding(.vertical, 6)
                    }
                    .onChange(of: Shelf.shared.selected) { _ in
                        let f = store.filtered
                        if Shelf.shared.selected < f.count {
                            withAnimation { proxy.scrollTo(f[Shelf.shared.selected].id,
                                                           anchor: .center) }
                        }
                    }
                }
                // hint bar
                HStack(spacing: 18) {
                    hint("⏎", "paste"); hint("⌘1–9", "quick paste")
                    hint("←→", "select"); hint("⌫", "delete"); hint("⎋", "close")
                    Spacer()
                    if store.filtered.contains(where: { $0.pinned }) {
                        Label("Pinned first", systemImage: "pin.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 26).padding(.vertical, 10)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct CardView: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // accent strip
            clip.accent.frame(height: 3).clipShape(
                .rect(topLeadingRadius: 14, topTrailingRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if let ic = clip.appIcon {
                        Image(nsImage: ic).resizable().frame(width: 18, height: 18)
                    }
                    Text(clip.appName).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(clip.typeLabel)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(clip.accent.opacity(0.18)))
                        .foregroundStyle(clip.accent)
                    if clip.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                if let img = clip.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Text(clip.preview)
                        .font(.system(size: 13))
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                }
                HStack {
                    Text(clip.date, style: .time)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 240, height: 200)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(selected ? Color.accentColor
                             : Color.primary.opacity(hovered ? 0.18 : 0.06),
                    lineWidth: selected ? 2.5 : 1))
        .scaleEffect(selected ? 1.04 : (hovered ? 1.02 : 1))
        .shadow(color: .black.opacity(selected ? 0.25 : 0.12),
                radius: selected ? 14 : 6, y: selected ? 6 : 3)
        .animation(.spring(duration: 0.2), value: selected)
        .animation(.spring(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let m = v as? T { return m }
            if let d = v.firstDescendant(of: type) { return d }
        }
        return nil
    }
}

// MARK: - Hotkey + app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var hotkey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = Shelf.shared            // prewarm — its init builds ShelfView
        Store.shared.start()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                       accessibilityDescription: "clipdeck")
        let m = NSMenu()
        let show = NSMenuItem(title: "Show clipdeck", action: #selector(toggle), keyEquivalent: "v")
        show.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(show)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Clear History (keep pinned)",
                             action: #selector(clear), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit clipdeck", action: #selector(quit), keyEquivalent: "q"))
        status.menu = m
        installHotkey()
    }

    @objc func toggle() {
        Shelf.shared.prevApp = NSWorkspace.shared.frontmostApplication
        Shelf.shared.toggle()
    }
    @objc func clear() { Store.shared.clearUnpinned() }
    @objc func quit() { NSApp.terminate(nil) }

    private func installHotkey() {
        var t = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            FileHandle.standardError.write("clipdeck: hotkey fired\n".data(using: .utf8)!)
            DispatchQueue.main.async {
                Shelf.shared.prevApp = NSWorkspace.shared.frontmostApplication
                Shelf.shared.toggle()
            }
            return noErr
        }, 1, &t, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x70617374), id: 1) // 'past'
        let err = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotkey)
        FileHandle.standardError.write("clipdeck: RegisterEventHotKey -> \(err)\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
