//
//  ThemeEditorView.swift — browse, preview, create, edit, import and export
//  terminal themes. Built-in themes are read-only (duplicate to edit); the
//  preview is a real terminal view, so it shows exactly what tabs will.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThemeEditorView: View {
    static let size = NSSize(width: 980, height: 720)

    @ObservedObject var store: ThemeStore
    @State private var selection: String?
    @State private var draft: Theme?
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var fonts: [ThemeEditing.FontChoice] = []

    init(store: ThemeStore, selection: String? = nil) {
        self.store = store
        _selection = State(initialValue: selection ?? store.catalog.themes.first?.id)
    }

    private var catalog: ThemeCatalog { store.catalog }
    private var editable: Bool { draft.map { ThemeEditing.canEdit($0.id, in: catalog) } ?? false }
    private var saved: Theme? { selection.flatMap(catalog.theme) }
    private var dirty: Bool { editable && draft != saved }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            if draft != nil {
                detail
            } else {
                ContentUnavailableView("No Theme Selected", systemImage: "paintpalette",
                                       description: Text("Choose a theme to preview it."))
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            fonts = ThemeEditing.monospacedFonts()
            draft = saved
        }
        .onChange(of: selection) { draft = saved }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                           set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Delete “\(draft?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete Theme", role: .destructive) { deleteSelected() }
        } message: {
            Text("Tabs and VMs using it switch to Automatic.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Built-in") {
                ForEach(catalog.themes.filter { catalog.isBuiltIn($0.id) }) { row($0) }
            }
            Section("My Themes") {
                let mine = catalog.themes.filter { !catalog.isBuiltIn($0.id) }
                if mine.isEmpty {
                    Text("Duplicate a theme or import one.").font(Design.caption).foregroundStyle(.secondary)
                }
                ForEach(mine) { row($0) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button { newTheme() } label: { Image(systemName: "plus") }.help("New theme")
                Button { duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate").disabled(draft == nil)
                Button { confirmDelete = true } label: { Image(systemName: "minus") }
                    .help("Delete").disabled(!editable)
                Spacer()
                Menu {
                    Button("Import…") { importTheme() }
                    Menu("Export") {
                        ForEach(ThemeEditing.ExportFormat.allCases) { f in
                            Button(f.title) { export(as: f) }
                        }
                    }
                    .disabled(draft == nil)
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Import or export")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func row(_ t: Theme) -> some View {
        HStack(spacing: 10) {
            Text("Aa")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: t.foreground.nsColor))
                .frame(width: 34, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: t.background.nsColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).font(Design.body)
                if store.defaultThemeID == t.id {
                    Text("App default").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .tag(t.id)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let theme = draft {
            VStack(spacing: 0) {
                header(theme)
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
                ThemePreview(theme: theme)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .padding(.horizontal, 20)
                // Each section disabled, not the form: a disabled form does
                // not scroll, and a built-in theme's settings are to be read.
                Form {
                    colors.disabled(!editable)
                    ansi.disabled(!editable)
                    window.disabled(!editable)
                    typeAndCursor.disabled(!editable)
                    image.disabled(!editable)
                }
                .formStyle(.grouped)
                .font(Design.body)
                if editable { saveBar }
            }
        }
    }

    /// Outside the form: its buttons work for read-only themes too.
    private func header(_ theme: Theme) -> some View {
        HStack {
            if editable {
                TextField("Name", text: bind(\.name)).textFieldStyle(.roundedBorder).font(Design.rowTitle)
                    .frame(maxWidth: 320)
            } else {
                Text(theme.name).font(.system(size: 20, weight: .bold))
                TagLabel(text: "built-in")
            }
            Spacer()
            if !editable {
                Button("Duplicate to Edit") { duplicateSelected() }
            }
            Button(store.defaultThemeID == theme.id ? "App Default" : "Use as App Default") {
                store.defaultThemeID = theme.id
            }
            .disabled(store.defaultThemeID == theme.id || dirty)
        }
        .controlSize(.large)
    }

    private var colors: some View {
        Section("Colors") {
            colorRow("Text", "textformat", .blue, \.foreground)
            HStack {
                SettingRow(symbol: "bold", color: .indigo, title: "Bold text") {
                    Toggle("Own color", isOn: Binding(get: { draft?.bold != nil },
                                                      set: { draft?.bold = $0 ? draft?.foreground : nil }))
                        .toggleStyle(.checkbox)
                    if draft?.bold != nil {
                        ColorPicker("", selection: colorBinding(get: { $0.bold ?? $0.foreground },
                                                                set: { $0.bold = $1 }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
            colorRow("Background", "rectangle.fill", .gray, \.background)
            colorRow("Cursor", "character.cursor.ibeam", .orange, \.cursor)
            colorRow("Selection", "selection.pin.in.out", .teal, \.selection)
        }
    }

    private var ansi: some View {
        Section {
            ForEach([0, 8], id: \.self) { start in
                HStack(spacing: 10) {
                    Text(start == 0 ? "Normal" : "Bright").font(Design.caption).foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .leading)
                    ForEach(start..<start + 8, id: \.self) { i in
                        ColorPicker("", selection: colorBinding(get: { $0.ansi[i] }, set: { $0.ansi[i] = $1 }),
                                    supportsOpacity: false)
                            .labelsHidden()
                            .help(ThemeImport.ansiNames[i % 8] + (i >= 8 ? " (bright)" : ""))
                    }
                }
            }
        } header: {
            Text("ANSI Colors")
        } footer: {
            Text("Black, red, green, yellow, blue, magenta, cyan and white. Programs pick from these.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
    }

    private var window: some View {
        Section("Window") {
            percentRow("Background opacity", "square.on.square.dashed", .purple, \.backgroundOpacity,
                       detail: "Lower lets the desktop show through. Text and colored cells stay solid.")
            percentRow("Blur", "drop", .cyan, \.blur, detail: "Blurs the background image, and the desktop behind a translucent background.")
        }
    }

    private var typeAndCursor: some View {
        Section("Font and Cursor") {
            SettingRow(symbol: "textformat.alt", color: .green, title: "Font",
                       detail: "The size is set in Settings (⌘+ and ⌘− in any tab).") {
                Picker("", selection: bind(\.font)) {
                    Text("System Monospaced").tag(String?.none)
                    Divider()
                    ForEach(fonts) { Text($0.displayName).tag(String?.some($0.postScriptName)) }
                    if let f = draft?.font, !fonts.contains(where: { $0.postScriptName == f }) {
                        Text("\(f) (not installed)").tag(String?.some(f))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            SettingRow(symbol: "cursorarrow", color: .orange, title: "Cursor",
                       detail: "Programs may still choose their own.") {
                Picker("", selection: bind(\.cursorStyle)) {
                    Text("Block").tag(Theme.CursorStyle?.some(.block))
                    Text("Underline").tag(Theme.CursorStyle?.some(.underline))
                    Text("Bar").tag(Theme.CursorStyle?.some(.bar))
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private var image: some View {
        Section("Background Image") {
            SettingRow(symbol: "photo", color: .pink, title: "Image",
                       detail: draft?.backgroundImage?.path ?? "None. Large images are scaled down once and shared by all tabs.") {
                HStack {
                    if draft?.backgroundImage != nil {
                        Button("Remove") { draft?.backgroundImage = nil }
                    }
                    Button("Choose…") { chooseImage() }
                }
            }
            if draft?.backgroundImage != nil {
                SettingRow(symbol: "aspectratio", color: .gray, title: "Placement") {
                    Picker("", selection: Binding(get: { draft?.backgroundImage?.fill ?? .fill },
                                                  set: { draft?.backgroundImage?.fill = $0 })) {
                        Text("Fill").tag(Theme.BackgroundImage.Fill.fill)
                        Text("Fit").tag(Theme.BackgroundImage.Fill.fit)
                        Text("Stretch").tag(Theme.BackgroundImage.Fill.stretch)
                        Text("Center").tag(Theme.BackgroundImage.Fill.center)
                        Text("Tile").tag(Theme.BackgroundImage.Fill.tile)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                percentRow("Image opacity", "circle.lefthalf.filled", .gray,
                           \.imageOpacity, detail: nil)
            }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if dirty { Text("Unsaved changes").font(Design.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Revert") { draft = saved }.disabled(!dirty)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            .controlSize(.large)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Rows and bindings

    private func bind<V>(_ path: WritableKeyPath<Theme, V>) -> Binding<V> {
        Binding(get: { draft![keyPath: path] }, set: { draft?[keyPath: path] = $0 })
    }

    private func colorBinding(get: @escaping (Theme) -> RGB, set: @escaping (inout Theme, RGB) -> Void) -> Binding<Color> {
        Binding(get: { Color(nsColor: get(draft!).nsColor) },
                set: { new in if draft != nil { set(&draft!, RGB(nsColor: NSColor(new))) } })
    }

    private func colorRow(_ title: String, _ symbol: String, _ color: Color, _ path: WritableKeyPath<Theme, RGB>) -> some View {
        SettingRow(symbol: symbol, color: color, title: title) {
            ColorPicker("", selection: colorBinding(get: { $0[keyPath: path] }, set: { $0[keyPath: path] = $1 }),
                        supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func percentRow(_ title: String, _ symbol: String, _ color: Color, _ path: WritableKeyPath<Theme, Double>,
                            detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(symbol: symbol, color: color, title: title, detail: detail) {
                Text("\(Int(((draft?[keyPath: path] ?? 0) * 100).rounded()))%").font(Design.value)
            }
            Slider(value: bind(path), in: 0...1, step: 0.01) { Text(title) }
                .labelsHidden()
                .padding(.leading, 38)
        }
    }

    // MARK: Actions

    private func save() {
        guard let draft else { return }
        do {
            try store.save(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ theme: Theme) {
        do {
            try store.save(theme)
            selection = theme.id
            draft = theme
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func newTheme() {
        let names = Set(catalog.themes.map(\.name))
        var name = "New Theme", n = 2
        while names.contains(name) {
            name = "New Theme \(n)"
            n += 1
        }
        var t = Theme.monadDark
        t.name = name
        t.id = catalog.newID(for: name)
        add(t)
    }

    private func duplicateSelected() {
        guard let t = draft else { return }
        add(ThemeEditing.duplicate(t, in: catalog))
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        do {
            try store.delete(id)
            if store.defaultThemeID == id { store.defaultThemeID = ThemeCatalog.automaticID }
            selection = catalog.themes.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["terminal", "itermcolors"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            add(try ThemeImport.file(url, catalog: catalog))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(as format: ThemeEditing.ExportFormat) {
        guard let theme = draft else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(theme.name).\(format == .monad ? "theme.json" : format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeEditing.export(theme, as: format).write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft?.backgroundImage = .init(path: url.path, fill: .fill, opacity: 0.35)
    }
}

private extension Theme {
    /// Bound for the image opacity slider (only shown when there is an image).
    var imageOpacity: Double {
        get { backgroundImage?.opacity ?? 1 }
        set { backgroundImage?.opacity = newValue }
    }
}

/// A real terminal view showing sample output in a theme.
struct ThemePreview: NSViewRepresentable {
    let theme: Theme

    func makeNSView(context: Context) -> TerminalBackdropView {
        // Scrollback and a realistic first size keep the sample through the
        // first layouts (a tiny view would reflow it away).
        let model = TerminalModel(cols: 72, rows: 9, scrollback: 500)!
        let terminal = MonadTerminalView(model: model)
        let backdrop = TerminalBackdropView(terminal: terminal)
        backdrop.frame = NSRect(x: 0, y: 0, width: 900, height: 190)
        model.feed(ThemeEditing.previewSample)
        terminal.refresh()
        backdrop.setTheme(theme)
        return backdrop
    }

    func updateNSView(_ view: TerminalBackdropView, context: Context) {
        if view.terminal.chosenTheme != theme { view.setTheme(theme) }
    }
}

#if DEBUG
#Preview("Theme Editor") {
    ThemeEditorView(store: ThemeStore(catalog: .load(builtIn: Bundle.main.resourceURL, user: nil)), selection: "pro")
        .frame(width: ThemeEditorView.size.width, height: ThemeEditorView.size.height)
}
#endif
