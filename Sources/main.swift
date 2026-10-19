import Cocoa
import Carbon.HIToolbox

// paster — free Paste-style clipboard manager.
// Menubar agent + bottom shelf of history cards on ⌘⇧V.

// MARK: - Store

struct Clip: Identifiable {
    let id = UUID()
    let date = Date()
    let kind: Kind
    enum Kind { case text(String), image(Data), file([String]) }
    var pinned = false
    var appIcon: NSImage?       // icon of the app that copied it
    var appName: String = ""

    var preview: String {
        switch kind {
        case .text(let s):  return String(s.prefix(200))
        case .image:        return "Image"
        case .file(let f):  return f.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }
    var image: NSImage? {
        if case .image(let d) = kind { return NSImage(data: d) }
        return nil
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
}

final class Store: ObservableObject {
    static let shared = Store()
    @Published private(set) var items: [Clip] = []
    @Published var query = ""
    var capacity = 200
    private var ignoredApps = Set<String>()   // bundle IDs
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    var filtered: [Clip] {
        let q = query.lowercased()
        return items.filter { q.isEmpty || $0.preview.lowercased().contains(q) }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.poll()
        }
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
        if let i = items.firstIndex(where: { $0.preview == c.preview }) {
            items.remove(at: i)               // dedupe → move to top
        }
        items.insert(c, at: 0)
        let unpinned = items.filter { !$0.pinned }
        if unpinned.count > capacity, let last = unpinned.last,
           let idx = items.firstIndex(where: { $0.id == last.id }) {
            items.remove(at: idx)
        }
    }

    func pin(_ c: Clip) {
        if let i = items.firstIndex(where: { $0.id == c.id }) { items[i].pinned.toggle() }
        items.sort { ($0.pinned ? 0 : 1, -$0.date.timeIntervalSince1970)
                   < ($1.pinned ? 0 : 1, -$1.date.timeIntervalSince1970) }
    }
    func delete(_ c: Clip) { items.removeAll { $0.id == c.id } }
    func paste(_ c: Clip) {
        c.write(to: .general)
        lastChange = NSPasteboard.general.changeCount  // don't re-add own paste
        Shelf.shared.hide()
        // synthetic ⌘V into the previously-front app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
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
    private let list = NSCollectionView()
    private var keyMon: Any?

    private init() {
        let r = CGRect(x: 0, y: 0, width: NSScreen.main?.frame.width ?? 1400, height: 300)
        super.init(contentRect: r,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        isOpaque = false; backgroundColor = .clear
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        let host = NSHostingView(rootView: ShelfView())
        host.frame = NSRect(origin: .zero, size: r.size)
        contentView = host
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let s = NSScreen.main else { return }
        setFrame(CGRect(x: s.frame.minX, y: s.frame.minY,
                        width: s.frame.width, height: 300), display: true)
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { Shelf.shared.hide(); return nil }   // ⎋
            if e.keyCode == 36 { Shelf.shared.pasteSelected(); return nil } // ⏎
            if e.keyCode == 51 { Shelf.shared.deleteSelected(); return nil } // ⌫
            // digits 1-9 → paste nth item
            if let n = Int(e.characters ?? ""), (1...9).contains(n) {
                Shelf.shared.pasteIndex(n - 1); return nil
            }
            // arrows
            if e.keyCode == 123 { Shelf.shared.moveSel(-1); return nil }
            if e.keyCode == 124 { Shelf.shared.moveSel(1); return nil }
            return e
        }
    }

    func hide() {
        if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        orderOut(nil)
        if let app = prevApp { app.activate(options: .activateIgnoringOtherApps) }
    }

    var prevApp: NSRunningApplication?
    var selected = 0

    func moveSel(_ d: Int) {
        let n = Store.shared.filtered.count
        if n > 0 { selected = (selected + d + n) % n }
        refresh()
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
        if selected < f.count { Store.shared.delete(f[selected]) }
        refresh()
    }
    func refresh() {
        (contentView as? NSHostingView<ShelfView>)?.rootView = ShelfView()
    }
}

// MARK: - SwiftUI cards

import SwiftUI

struct ShelfView: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                TextField("Search clipboard…", text: $store.query)
                    .textFieldStyle(.plain).font(.title3)
                Text("\(store.items.count) items").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            Divider().opacity(0.3)
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(Array(store.filtered.prefix(60).enumerated()), id: \.element.id) { i, c in
                        CardView(clip: c, index: i,
                                 selected: i == Shelf.shared.selected)
                            .onTapGesture {
                                Shelf.shared.selected = i
                                Shelf.shared.pasteSelected()
                            }
                            .contextMenu {
                                Button(c.pinned ? "Unpin" : "Pin") { store.pin(c); Shelf.shared.refresh() }
                                Button("Paste as plain text") { store.paste(c) }
                                Divider()
                                Button("Delete") { store.delete(c); Shelf.shared.refresh() }
                            }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
            }
        }
        .background(.ultraThinMaterial)
        .task { Shelf.shared.selected = min(Shelf.shared.selected, max(0, store.filtered.count - 1)) }
    }
}

struct CardView: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let ic = clip.appIcon {
                    Image(nsImage: ic).resizable().frame(width: 18, height: 18)
                }
                Text(clip.appName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if index < 9 {
                    Text("⌘\(index+1)").font(.caption2).foregroundStyle(.tertiary)
                }
                if clip.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
            }
            if let img = clip.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(clip.preview).font(.system(size: 13))
                    .lineLimit(7).frame(maxWidth: .infinity, maxHeight: .infinity,
                                        alignment: .topLeading)
            }
            Text(clip.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 220, height: 160)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        .shadow(radius: selected ? 8 : 2)
    }
}

// MARK: - Hotkey + app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var hotkey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Store.shared.start()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                       accessibilityDescription: "paster")
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Show paster", action: #selector(show), keyEquivalent: "v"))
        m.items[0].keyEquivalentModifierMask = [.command, .shift]
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Clear history", action: #selector(clear), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Quit paster", action: #selector(quit), keyEquivalent: "q"))
        status.menu = m
        installHotkey()
    }

    @objc func show() { Shelf.shared.toggle() }
    @objc func clear() {
        Store.shared.items.forEach { if !$0.pinned { Store.shared.delete($0) } }
    }
    @objc func quit() { NSApp.terminate(nil) }

    private func installHotkey() {
        // ⌘⇧V — Carbon hotkey (works while another app is frontmost)
        var t = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            NSLog("paster: hotkey fired")
            DispatchQueue.main.async {
                Shelf.shared.prevApp = NSWorkspace.shared.frontmostApplication
                Shelf.shared.toggle()
            }
            return noErr
        }, 1, &t, nil, nil)
        var id = EventHotKeyID(signature: OSType(0x70617374), id: 1) // 'past'
        let err = RegisterEventHotKey(UInt32(kVK_ANSI_V),
                            UInt32(cmdKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotkey)
        NSLog("paster: RegisterEventHotKey -> %d", err)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
