//
//  ThemeChoice.swift — which theme a tab uses (its own choice, else its VM's,
//  else the app default), the shared catalog and app default, and the Theme
//  menu.
//

import AppKit
import Combine

enum ThemeChoice {
    /// The theme to draw with; nil means follow the appearance (Automatic,
    /// or a theme that no longer exists).
    static func effective(tab: String?, vm: String?, app: String, catalog: ThemeCatalog) -> Theme? {
        let id = tab ?? vm ?? app
        return id == ThemeCatalog.automaticID ? nil : catalog.theme(id)
    }
}

/// The themes and the app default, shared by every window.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let changed = Notification.Name("dev.monad.themesChanged")
    static let defaultKey = "defaultTheme"

    @Published private(set) var catalog: ThemeCatalog

    init(catalog: ThemeCatalog = .live()) {
        self.catalog = catalog
    }

    /// The app default: a theme id or "automatic".
    var defaultThemeID: String {
        get { UserDefaults.standard.string(forKey: Self.defaultKey) ?? ThemeCatalog.automaticID }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.defaultKey)
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func reload() {
        catalog = .live()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func save(_ theme: Theme) throws {
        try catalog.save(theme)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func delete(_ id: String) throws {
        try catalog.delete(id)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// The per-tab Theme menu.
enum ThemeMenu {
    static let defaultTitle = "Use VM or App Default"

    @MainActor
    static func fill(_ menu: NSMenu, catalog: ThemeCatalog, selected: String?, action: Selector) {
        menu.removeAllItems()
        func add(_ title: String, _ id: String?) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.representedObject = id
            item.state = selected == id ? .on : .off
        }
        add(defaultTitle, nil)
        menu.addItem(.separator())
        add("Automatic (Light/Dark)", ThemeCatalog.automaticID)
        var lastBuiltIn: Bool?
        for t in catalog.themes {
            let builtIn = catalog.isBuiltIn(t.id)
            if let last = lastBuiltIn, last != builtIn { menu.addItem(.separator()) }
            lastBuiltIn = builtIn
            add(t.name, t.id)
        }
    }
}
