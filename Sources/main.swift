import Cocoa
import Carbon.HIToolbox
import SwiftUI

// ClipDesk — free clipboard manager, Spotlight-style center palette.

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
        let target = Palette.shared.prevApp
        Palette.shared.hide(restoreFocus: false)
        target?.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !AXIsProcessTrusted() {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                return
            }
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

// MARK: - Palette window (Spotlight-style centered)

final class Palette: NSWindow {
    static let shared = Palette()
    private var keyMon: Any?
    private var globalMon: Any?
    var prevApp: NSRunningApplication?
    var selected = 0
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
        isMovableByWindowBackground = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        isOpaque = false; backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces]
        contentView = NSHostingView(rootView: PaletteView())
    }

    func toggle() { shown ? hide() : show() }

    func show() {
        guard let s = NSScreen.main else { return }
        selected = 0
        contentView = NSHostingView(rootView: PaletteView())
        let w: CGFloat = 720, h: CGFloat = 460
        setFrame(CGRect(x: s.frame.midX - w/2,
                        y: s.frame.minY + s.frame.height * 0.62,
                        width: w, height: h), display: true)
        alphaValue = 0
        orderFrontRegardless()
        shown = true
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(resignedKey),
            name: NSWindow.didResignKeyNotification, object: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let tf = self.contentView?.firstDescendant(of: NSTextField.self) {
                self.makeFirstResponder(tf)
            }
        }
        // local: while palette is key
        keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 53:  Palette.shared.hide(); return nil
            case 36:  Palette.shared.pasteSelected(); return nil
            case 51:  Palette.shared.deleteSelected(); return nil
            case 125: Palette.shared.moveSel(1); return nil    // ↓
            case 126: Palette.shared.moveSel(-1); return nil   // ↑
            default: break
            }
            if e.modifierFlags.contains(.command), let n = Int(e.characters ?? ""),
               (1...9).contains(n) {
                Palette.shared.pasteIndex(n - 1); return nil
            }
            return e
        }
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { DispatchQueue.main.async { Palette.shared.hide() } }
        }
    }

    @objc private func resignedKey() {
        // don't hide while the AX prompt or our own click animation is in flight
        if shown { hide() }
    }

    func hide(restoreFocus: Bool = true) {
        shown = false
        NotificationCenter.default.removeObserver(self,
            name: NSWindow.didResignKeyNotification, object: self)
        if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        if let m = globalMon { NSEvent.removeMonitor(m); globalMon = nil }
        Store.shared.query = ""
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
            if restoreFocus, let app = self.prevApp {
                app.activate(options: .activateIgnoringOtherApps)
            }
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
    func refresh() { contentView = NSHostingView(rootView: PaletteView()) }
    func refreshSoon() { DispatchQueue.main.async { self.refresh() } }
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

// MARK: - SwiftUI — Spotlight palette layout

struct PaletteView: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        VStack(spacing: 0) {
            // big search row
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
                TextField("Search clipboard…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .regular))
                if !store.query.isEmpty {
                    Text("\(store.filtered.count)")
                        .font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            Divider().opacity(0.4)

            if store.filtered.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(store.query.isEmpty
                         ? "Copy anything — it lands here"
                         : "No matches for “\(store.query)”")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                HStack(spacing: 0) {
                    // left: rows
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(store.filtered.prefix(80).enumerated()),
                                        id: \.element.id) { i, c in
                                    RowView(clip: c, index: i,
                                            selected: i == Palette.shared.selected)
                                        .id(c.id)
                                        .onTapGesture {
                                            Palette.shared.selected = i
                                            Palette.shared.pasteSelected()
                                        }
                                        .contextMenu {
                                            Button(c.pinned ? "Unpin" : "Pin to top") {
                                                store.pin(c); Palette.shared.refreshSoon()
                                            }
                                            Button("Paste as plain text") {
                                                store.paste(c, plain: true)
                                            }
                                            Divider()
                                            Button("Delete") {
                                                store.delete(c); Palette.shared.refreshSoon()
                                            }
                                        }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(width: 420)
                        .onChange(of: Palette.shared.selected) { _ in
                            let f = store.filtered
                            if Palette.shared.selected < f.count {
                                withAnimation {
                                    proxy.scrollTo(f[Palette.shared.selected].id)
                                }
                            }
                        }
                    }

                    Divider().opacity(0.4)

                    // right: preview pane of selected item
                    if Palette.shared.selected < store.filtered.count {
                        PreviewPane(clip: store.filtered[Palette.shared.selected])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            Divider().opacity(0.4)
            // hint footer
            HStack(spacing: 16) {
                hint("⏎", "paste"); hint("↑↓", "select")
                hint("⌘1–9", "quick paste"); hint("⌫", "delete"); hint("⎋", "close")
                Spacer()
                if store.filtered.contains(where: { $0.pinned }) {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 9)
            .background(.quaternary.opacity(0.4))
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(.white.opacity(0.12), lineWidth: 0.5))
        .padding(1)
    }

    func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RowView: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            // type dot
            Circle().fill(clip.accent).frame(width: 8, height: 8)
            if let ic = clip.appIcon {
                Image(nsImage: ic).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "doc").frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.preview)
                    .font(.system(size: 13.5))
                    .lineLimit(2).truncationMode(.tail)
                Text("\(clip.appName) · \(clip.date, style: .time)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if clip.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Color.accentColor.opacity(0.22)
                           : (hovered ? Color.primary.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

struct PreviewPane: View {
    let clip: Clip
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(clip.typeLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(clip.accent.opacity(0.18)))
                    .foregroundStyle(clip.accent)
                Spacer()
                Text(clip.date, style: .time).font(.caption).foregroundStyle(.tertiary)
            }
            if let img = clip.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView {
                    Text(clip.preview)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            HStack {
                if let ic = clip.appIcon {
                    Image(nsImage: ic).resizable().frame(width: 16, height: 16)
                }
                Text(clip.appName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

// MARK: - Settings

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var launchAtLogin: Bool { didSet {
        d.set(launchAtLogin, forKey: "launchAtLogin")
        applyLogin()
    } }
    @Published var hideMenubarIcon: Bool { didSet {
        d.set(hideMenubarIcon, forKey: "hideMenubarIcon")
        applyMenubar()
    } }
    @Published var capacity: Double { didSet {
        d.set(capacity, forKey: "capacity")
        Store.shared.capacity = Int(capacity)
    } }

    private init() {
        d.register(defaults: ["launchAtLogin": false,
                              "hideMenubarIcon": false, "capacity": 200.0])
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        hideMenubarIcon = d.bool(forKey: "hideMenubarIcon")
        capacity = d.double(forKey: "capacity")
    }

    func applyLogin() {
        if #available(macOS 13, *) {
            let s = SMAppService.mainApp
            try? launchAtLogin ? s.register() : s.unregister()
        }
    }
    func applyMenubar() {
        if let b = NSApp.delegate as? AppDelegate {
            b.status?.isVisible = !hideMenubarIcon
        }
    }
}

import ServiceManagement

struct SettingsView: View {
    @ObservedObject var p = Prefs.shared
    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $p.launchAtLogin)
                Toggle("Hide menubar icon (⌘⇧V still works)",
                       isOn: $p.hideMenubarIcon)
            }
            Section("History") {
                HStack {
                    Text("Capacity")
                    Slider(value: $p.capacity, in: 50...1000, step: 50)
                    Text("\(Int(p.capacity))").monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
        .padding(10)
    }
}

// MARK: - Hotkey + app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var hotkey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = Palette.shared
        Store.shared.start()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                       accessibilityDescription: "ClipDesk")
        let m = NSMenu()
        let show = NSMenuItem(title: "Show ClipDesk", action: #selector(toggle), keyEquivalent: "v")
        show.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(show)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Clear History (keep pinned)",
                             action: #selector(clear), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Settings…", action: #selector(settings), keyEquivalent: ","))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit ClipDesk", action: #selector(quit), keyEquivalent: "q"))
        status.menu = m
        Prefs.shared.applyMenubar()
        Prefs.shared.applyLogin()
        installHotkey()
    }

    @objc func toggle() {
        Palette.shared.prevApp = NSWorkspace.shared.frontmostApplication
        Palette.shared.toggle()
    }
    @objc func clear() { Store.shared.clearUnpinned() }

    var settingsWin: NSWindow?
    @objc func settings() {
        if settingsWin == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ClipDesk Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            w.isReleasedWhenClosed = false
            settingsWin = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWin?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }

    private func installHotkey() {
        var t = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                Palette.shared.prevApp = NSWorkspace.shared.frontmostApplication
                Palette.shared.toggle()
            }
            return noErr
        }, 1, &t, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x636c6970), id: 1) // 'clip'
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotkey)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
