import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import CryptoKit

// MARK: - Model

struct Clip: Codable, Identifiable {
    var id = UUID()
    var text: String?
    var isImage = false
    var date = Date()
    var favorite: Bool? // optional so history saved before favorites existed still decodes

    var isFavorite: Bool { favorite == true }
    var isNumber: Bool {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 64 else { return false }
        return t.contains(where: \.isNumber) && t.allSatisfy { $0.isNumber || " +-.,()/".contains($0) }
    }
}

enum Filter: String, CaseIterable {
    case all = "All", favorites = "Favorites", text = "Text", images = "Images", numbers = "Numbers"

    var icon: String {
        switch self {
        case .all: "tray.full"
        case .favorites: "star.fill"
        case .text: "textformat"
        case .images: "photo"
        case .numbers: "number"
        }
    }

    func matches(_ c: Clip) -> Bool {
        switch self {
        case .all: true
        case .favorites: c.isFavorite
        case .text: !c.isImage
        case .images: c.isImage
        case .numbers: c.isNumber
        }
    }
}

/// AES-256 key for history at rest, kept in the login Keychain.
enum Vault {
    static let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.sherazcoder.easyclipboard",
                                   kSecAttrAccount as String: "history-key"]

    static func deleteKey() { SecItemDelete(q as CFDictionary) }

    /// nil = Keychain refused (e.g. user clicked Deny) → caller must not overwrite existing data.
    static func key() -> SymmetricKey? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data { return SymmetricKey(data: d) }
        guard status == errSecItemNotFound else { return nil }
        let key = SymmetricKey(size: .bits256)
        let add = q.merging([kSecValueData as String: key.withUnsafeBytes { Data($0) }]) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}

final class Store: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var query = "" { didSet { selection = 0 } }
    @Published var filter = Filter.all { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var editing: UUID?
    @Published var draft = ""
    static let limit = 200 // favorites don't count toward this
    let dir: URL
    let key = Vault.key()
    var locked: Bool { key == nil }
    private var historyURL: URL { dir.appendingPathComponent("history.json") }
    private var lastChange = NSPasteboard.general.changeCount
    private let thumbs = NSCache<NSUUID, NSImage>()

    var filtered: [Clip] {
        clips.filter { filter.matches($0) && (query.isEmpty || $0.text?.localizedCaseInsensitiveContains(query) == true) }
    }

    init() {
        let fm = FileManager.default
        dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EasyClipboard")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) // owner only

        if key != nil, let raw = try? Data(contentsOf: historyURL) {
            if let saved = unseal(raw).flatMap({ try? JSONDecoder().decode([Clip].self, from: $0) }) {
                clips = saved
            } else if let plain = try? JSONDecoder().decode([Clip].self, from: raw) { // v1 plaintext → encrypt now
                clips = plain
                for c in plain where c.isImage {
                    if let png = try? Data(contentsOf: imageURL(c)), unseal(png) == nil, let enc = seal(png) {
                        try? enc.write(to: imageURL(c), options: .atomic)
                    }
                }
                save()
            } else { // unreadable (key changed?) → keep it aside, never overwrite silently
                try? fm.moveItem(at: historyURL, to: historyURL.appendingPathExtension("\(Int(Date().timeIntervalSince1970)).bak"))
            }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func seal(_ d: Data) -> Data? { key.flatMap { try? AES.GCM.seal(d, using: $0).combined } }
    private func unseal(_ d: Data) -> Data? {
        key.flatMap { k in (try? AES.GCM.SealedBox(combined: d)).flatMap { try? AES.GCM.open($0, using: k) } }
    }

    func imageURL(_ c: Clip) -> URL { dir.appendingPathComponent("\(c.id).png") }

    func image(_ c: Clip) -> NSImage? {
        if let img = thumbs.object(forKey: c.id as NSUUID) { return img }
        guard let raw = try? Data(contentsOf: imageURL(c)), let img = unseal(raw).flatMap(NSImage.init(data:)) else { return nil }
        thumbs.setObject(img, forKey: c.id as NSUUID)
        return img
    }

    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // Password managers mark secrets with these types — never store them.
        let skip: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        if pb.types?.contains(where: { skip.contains($0.rawValue) }) == true { return }

        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fav = clips.first { $0.text == s }?.favorite
            clips.removeAll { $0.text == s }
            clips.insert(Clip(text: s, favorite: fav), at: 0)
        } else if let tiff = NSImage(pasteboard: pb)?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  let enc = seal(png) {
            let c = Clip(isImage: true)
            try? enc.write(to: imageURL(c), options: .atomic)
            clips.insert(c, at: 0)
        } else { return }
        while clips.filter({ !$0.isFavorite }).count > Self.limit, let old = clips.last(where: { !$0.isFavorite }) {
            delete(old)
        }
        save()
    }

    func copy(_ c: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = c.text { pb.setString(t, forType: .string) }
        else if let img = image(c) { pb.writeObjects([img]) }
        lastChange = pb.changeCount
        guard let i = clips.firstIndex(where: { $0.id == c.id }) else { return }
        clips.insert(clips.remove(at: i), at: 0) // keep latest state (e.g. favorite flag)
        save()
    }

    func delete(_ c: Clip) {
        clips.removeAll { $0.id == c.id }
        if c.isImage { try? FileManager.default.removeItem(at: imageURL(c)) }
        save()
    }

    func toggleFavorite(_ c: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == c.id }) else { return }
        clips[i].favorite = !clips[i].isFavorite
        save()
    }

    func beginEdit(_ c: Clip) {
        guard let t = c.text else { return }
        draft = t
        editing = c.id
    }

    func saveEdit() {
        if let id = editing, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let i = clips.firstIndex(where: { $0.id == id }) {
            clips[i].text = draft
            clips.removeAll { $0.text == draft && $0.id != id && !$0.isFavorite }
            save()
        }
        editing = nil
    }

    /// Clears everything except favorites.
    func clear() {
        clips.filter { $0.isImage && !$0.isFavorite }.forEach { try? FileManager.default.removeItem(at: imageURL($0)) }
        clips.removeAll { !$0.isFavorite }
        save()
    }

    private func save() {
        guard let enc = (try? JSONEncoder().encode(clips)).flatMap(seal) else { return } // locked → don't touch disk
        try? enc.write(to: historyURL, options: .atomic)
    }
}

// MARK: - UI

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active // app never activates, so force the active look
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

extension View {
    // set() not push/pop: a button removed mid-hover (delete) would leave the cursor stack unbalanced.
    func pointer() -> some View { onHover { ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() } }
}

struct IconButton: View {
    let symbol: String, help: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .help(help)
        .pointer()
    }
}

struct Row: View {
    let clip: Clip
    let store: Store
    let selected: Bool
    let paste: () -> Void
    let copy: () -> Void
    @State private var hover = false

    var body: some View {
        let active = hover || selected
        HStack(spacing: 2) {
            Group {
                if clip.isImage, let img = store.image(clip) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 64).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    // Max 2-line preview: newlines/tabs/space runs collapsed; paste still uses full text.
                    Text(String((clip.text ?? "").prefix(500)).split(whereSeparator: \.isWhitespace).joined(separator: " "))
                        .font(.system(size: 13)).lineLimit(2).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10).padding(.vertical, 8)
            // Tap-to-paste only on the content, so clicks on the buttons never also paste.
            .contentShape(Rectangle())
            .onTapGesture(perform: paste)
            // Buttons always laid out (just faded) so row height never jumps on hover.
            // Images have no edit button at all — no empty gap between icons.
            Group {
                IconButton(symbol: "doc.on.doc", help: "Copy", action: copy)
                if !clip.isImage { IconButton(symbol: "pencil", help: "Edit (⌘E)") { store.beginEdit(clip) } }
                IconButton(symbol: "trash", help: "Delete (⌘⌫)") { store.delete(clip) }
            }
            .opacity(active ? 1 : 0)
            IconButton(symbol: clip.isFavorite ? "star.fill" : "star", help: "Favorite (⌘D)",
                       tint: clip.isFavorite ? .yellow : nil) { store.toggleFavorite(clip) }
                .opacity(active || clip.isFavorite ? 1 : 0)
        }
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(hover ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct EditView: View {
    @ObservedObject var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit clip").font(.system(size: 13, weight: .semibold)).frame(height: 42)
            Divider()
            TextEditor(text: $store.draft)
                .font(.system(size: 13)).scrollContentBackground(.hidden).padding(8).focused($focused)
            Divider()
            HStack {
                Button("Cancel") { store.editing = nil }.pointer()
                Spacer()
                Text("⌘↩ save").font(.system(size: 10)).foregroundStyle(.secondary)
                Button("Save") { store.saveEdit() }.buttonStyle(.borderedProminent).pointer()
            }
            .padding(.horizontal, 10).frame(height: 40)
        }
        .onAppear { focused = true }
    }
}

struct HistoryView: View {
    @ObservedObject var store: Store
    let pick: (Clip) -> Void
    let copy: (Clip) -> Void
    @FocusState private var focused: Bool
    @State private var confirmClear = false

    var body: some View {
        Group {
            if store.editing != nil { EditView(store: store) } else { list }
        }
        .frame(width: 400, height: 460)
        .background(Blur())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    var emptyText: String {
        if store.locked { return "Keychain access denied — history can't be read" }
        if store.clips.isEmpty { return "Copy something to start" }
        if store.filter == .favorites && store.query.isEmpty { return "No favorites yet — tap ☆ on an item" }
        return "No matches"
    }

    var list: some View {
        let items = store.filtered
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $store.query)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                if store.locked { Image(systemName: "lock.slash").foregroundStyle(.red).help("Not saving: Keychain access denied") }
            }
            .padding(.horizontal, 12).frame(height: 42)
            HStack(spacing: 4) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button { store.filter = f } label: {
                        Label(f.rawValue, systemImage: f.icon)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1).fixedSize() // never wrap "Favorites"/"Numbers" onto 2 lines
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Capsule().fill(store.filter == f ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).pointer()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: store.filter == .favorites ? "star" : "clipboard").font(.system(size: 28))
                    Text(emptyText)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, clip in
                                // Identity = clip.id (from ForEach), NOT the index: index identity left
                                // context menus/hover bound to whichever clip used to sit at that position.
                                Row(clip: clip, store: store, selected: i == store.selection,
                                    paste: { pick(clip) }, copy: { copy(clip) })
                                    .contextMenu {
                                        Button("Paste") { pick(clip) }
                                        Button("Copy") { copy(clip) }
                                        Button(clip.isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(clip) }
                                        if !clip.isImage { Button("Edit") { store.beginEdit(clip) } }
                                        Divider()
                                        Button("Delete") { store.delete(clip) }
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: store.selection) { _, i in
                        if items.indices.contains(i) { proxy.scrollTo(items[i].id) }
                    }
                }
            }
            Divider()
            HStack {
                Text("↩ paste  ⇥ filter  ⌘D fav  ⌘E edit  ⌘⌫ delete")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(confirmClear ? "Sure? Clear" : "Clear All") {
                    if confirmClear { store.clear() }
                    confirmClear.toggle()
                }
                .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                .foregroundStyle(confirmClear ? Color.red : Color.secondary)
                .help("Clears everything except favorites")
                .disabled(store.clips.allSatisfy(\.isFavorite))
                .pointer()
            }
            .padding(.horizontal, 12).frame(height: 28)
        }
        .onAppear { focused = true }
    }
}

// MARK: - System glue

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private var hotKeyAction: (() -> Void)?

func registerHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in hotKeyAction?(); return noErr }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey), EventHotKeyID(signature: 0x434C4950, id: 1),
                        GetApplicationEventTarget(), 0, &ref)
}

/// Text caret rect of the focused field (Cocoa coords), via Accessibility. nil if the app doesn't expose it.
func caretRect() -> NSRect? {
    let sys = AXUIElementCreateSystemWide()
    var el: CFTypeRef?, range: CFTypeRef?, bounds: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &el) == .success,
          AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
          AXUIElementCopyParameterizedAttributeValue(el as! AXUIElement, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                     range!, &bounds) == .success
    else { return nil }
    var r = CGRect.zero
    guard AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.width + r.height > 0 else { return nil }
    let top = NSScreen.screens[0].frame.maxY
    return NSRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
}

func postCmdV() {
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
        e?.flags = .maskCommand
        e?.post(tap: .cghidEventTap)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var statusItem: NSStatusItem!
    var trashWatch: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ n: Notification) {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none // keep clipboard contents out of screenshots / screen sharing
        panel.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuIcon")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true // auto light/dark tint
        statusItem.button?.image = icon ?? NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Easy Clipboard")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show History  ⌃V", action: #selector(show), keyEquivalent: "").target = self
        // On by default: register once on first launch; after that the menu toggle owns it.
        if !UserDefaults.standard.bool(forKey: "loginDefaultApplied") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginDefaultApplied")
        }
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Clear History (keeps favorites)", action: #selector(clear), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall Easy Clipboard…", action: #selector(uninstall), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // macOS has no uninstall hook: if the app gets dragged to Trash while running, clean up after ourselves.
        // Kernel tells us the bundle's *current* path (F_GETPATH) on every rename, so moving it to another
        // folder is NOT treated as delete — only landing in a Trash is.
        let fd = open(Bundle.main.bundlePath, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .rename, queue: .main)
            src.setEventHandler { [weak self] in
                var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(fd, F_GETPATH, &buf) == 0 else { return }
                let path = String(cString: buf)
                if path.contains("/.Trash/") || path.contains("/.Trashes/") { self?.wipeAndExit() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            trashWatch = src
        }

        registerHotKey { [weak self] in
            guard let self else { return }
            self.panel.isVisible ? self.panel.orderOut(nil) : self.show()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) ?? e }
        // Needed for caret position + auto-paste. Prompts once.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    @objc func show() {
        store.query = ""
        store.filter = .all
        store.selection = 0
        store.editing = nil
        panel.contentView = NSHostingView(rootView: HistoryView(
            store: store,
            pick: { [weak self] in self?.paste($0) },
            copy: { [weak self] in self?.store.copy($0); self?.panel.orderOut(nil) }))

        let size = panel.frame.size
        let anchor = caretRect() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { NSMouseInRect(anchor.origin, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        var o = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if o.y < vf.minY { o.y = anchor.maxY + 6 } // no room below caret → open above
        o.x = min(max(o.x, vf.minX + 8), vf.maxX - size.width - 8)
        o.y = min(max(o.y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(o)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func paste(_ c: Clip) {
        panel.orderOut(nil)
        store.copy(c)
        // No permission → just copied; prompt so the user knows why paste didn't happen.
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { postCmdV() }
    }

    func handleKey(_ e: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return e }
        if store.editing != nil { // editor owns the keyboard except cancel/save
            if Int(e.keyCode) == kVK_Escape { store.editing = nil; return nil }
            if Int(e.keyCode) == kVK_Return && e.modifierFlags.contains(.command) { store.saveEdit(); return nil }
            return e
        }
        let items = store.filtered
        let selected = items.indices.contains(store.selection) ? items[store.selection] : nil
        let cmd = e.modifierFlags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_Escape: panel.orderOut(nil)
        case kVK_DownArrow: store.selection = max(0, min(store.selection + 1, items.count - 1))
        case kVK_UpArrow: store.selection = max(store.selection - 1, 0)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let c = selected { paste(c) }
        case kVK_Tab:
            let all = Filter.allCases, i = all.firstIndex(of: store.filter)!
            let step = e.modifierFlags.contains(.shift) ? all.count - 1 : 1
            store.filter = all[(i + step) % all.count]
        case kVK_ANSI_E where cmd:
            if let c = selected { store.beginEdit(c) }
        case kVK_ANSI_D where cmd:
            if let c = selected { store.toggleFavorite(c) }
        case kVK_Delete where cmd:
            if let c = selected {
                store.delete(c)
                store.selection = max(0, min(store.selection, items.count - 2))
            }
        default: return e
        }
        return nil
    }

    func windowDidResignKey(_ n: Notification) { panel.orderOut(nil) }

    @objc func clear() { store.clear() }

    @objc func uninstall() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Uninstall Easy Clipboard?"
        alert.informativeText = "This permanently deletes your clipboard history, favorites, encryption key and settings, then moves the app to the Trash."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in DispatchQueue.main.async { self.wipeAndExit() } }
    }

    /// Removes every trace the app leaves on disk / in the system, then exits.
    func wipeAndExit() {
        let id = Bundle.main.bundleIdentifier ?? "com.sherazcoder.easyclipboard"
        NSStatusBar.system.removeStatusItem(statusItem)
        try? SMAppService.mainApp.unregister()
        Vault.deleteKey()
        UserDefaults.standard.removePersistentDomain(forName: id) // status item position etc.
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for path in ["Caches/\(id)", "HTTPStorages/\(id)", "Saved Application State/\(id).savedState", "Preferences/\(id).plist"] {
            try? FileManager.default.removeItem(at: lib.appendingPathComponent(path))
        }
        try? FileManager.default.removeItem(at: store.dir) // history + images
        let tcc = try? Process.run(URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: ["reset", "Accessibility", id])
        tcc?.waitUntilExit()
        exit(0) // not terminate(): avoid AppKit writing state back on the way out
    }

    @objc func toggleLogin(_ item: NSMenuItem) {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } } catch { NSSound.beep() }
        item.state = s.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
