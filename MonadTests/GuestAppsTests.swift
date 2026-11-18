//
//  GuestAppsTests.swift — the graphical programs a Linux VM says it has
//  (GuestApps): the list its script prints and the icons it hands out are
//  the guest's words, read as hostile, and starting one names it only by
//  an id that can be nothing but an id.
//

import XCTest
@testable import Monad

final class GuestAppsTests: XCTestCase {
    private func list(_ text: String) -> [GuestApp]? { GuestApps.parseList(Data(text.utf8)) }

    /// The lines as Monad/Guest/monad-apps.sh prints them (CTests/test_apps.sh has the same).
    func testTheListIsRead() throws {
        let apps = try XCTUnwrap(list("app org.gnome.Calculator org.gnome.Calculator Calculator\n" +
                                      "app firefox_firefox /snap/firefox/current/icon.png Firefox%20Web%20Browser\n" +
                                      "app cafe - Caf%C3%A9%20%26%20Co\n" +
                                      "app dash - %2D\nend 4\n"))
        XCTAssertEqual(apps.map(\.id), ["org.gnome.Calculator", "firefox_firefox", "cafe", "dash"])
        XCTAssertEqual(apps.map(\.name), ["Calculator", "Firefox Web Browser", "Café & Co", "-"])
        XCTAssertEqual(list("end 0\n"), [])
        // An id the guest's script lets through and the Mac would rather not write as a word or a file name: that program is left out.
        XCTAssertEqual(list("app .hidden - A\napp -rf - B\napp ok - C\nend 3\n")?.map(\.id), ["ok"])
    }

    /// A name is the guest's: what would mislead in a menu is taken out, and one left with nothing is called by its id.
    func testANameIsMadeFitToShow() throws {
        let apps = try XCTUnwrap(list("app a - one%0Atwo%1B[31m\napp b - safe%E2%80%AEexe.txt\napp c - %00%09\napp d - %FF%FEname\nend 4\n"))
        XCTAssertEqual(apps[0].name, "onetwo[31m")
        XCTAssertEqual(apps[1].name, "safeexe.txt", "no turning the reading order around")
        XCTAssertEqual(apps[2].name, "c", "nothing left of the name: its id")
        XCTAssertEqual(apps[3].name, "\u{FFFD}\u{FFFD}name")
    }

    func testAListThatDoesNotFitIsNoList() {
        let bad: [(String, String)] = [
            ("app a - A\n", "no end"),
            ("app a - A\nend 2\n", "an end that counts otherwise"),
            ("app a - A\nend 1\napp b - B\n", "something after the end"),
            ("app a - A\nend 1", "a last line cut short"),
            ("app a - A\napp a - B\nend 2\n", "an id twice"),
            ("app ../../etc/passwd - A\nend 1\n", "an id that is a path"),
            ("app a -\nend 1\n", "a word missing"),
            ("app a%20b - A\nend 1\n", "an id that is no id"),
            ("app a - A B\nend 1\n", "a word too many"),
            ("app a  - A\nend 1\n", "an empty word"),
            ("app a - %ZZ\nend 1\n", "a %XX that is none"),
            ("app a - caf\u{e9}\nend 1\n", "bytes that are not plain text"),
            ("app a - A\tB\nend 1\n", "a control character"),
            ("run a - A\nend 1\n", "a line of another kind"),
            ("app a - A\nend 01\n", "a count written oddly"),
            ("app a - " + String(repeating: "%41", count: 129) + "\nend 1\n", "a name longer than any is"),
            ("app " + String(repeating: "a", count: 129) + " - A\nend 1\n", "an id longer than any is"),
            ("app a - " + String(repeating: "x", count: 2000) + "\nend 1\n", "a line longer than any is"),
        ]
        for (text, why) in bad { XCTAssertNil(list(text), why) }
        // More programs than a menu holds.
        let many = (0...GuestApps.maxApps).map { "app a\($0) - A\n" }.joined() + "end \(GuestApps.maxApps + 1)\n"
        XCTAssertNil(list(many))
        XCTAssertNil(GuestApps.parseList(Data(repeating: 0x61, count: GuestApps.maxListBytes + 1)), "more than a list is")
    }

    private let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private func stream(_ parts: [(String, [UInt8])], end: String = "end\n") -> Data {
        var data = Data()
        for (id, bytes) in parts {
            data.append(Data("icon \(id) \(bytes.count)\n".utf8))
            data.append(contentsOf: bytes)
        }
        data.append(Data(end.utf8))
        return data
    }

    /// Icons come as a line saying whose and how many bytes, then the bytes: PNG files, for the programs asked about.
    func testIconsAreReadForTheProgramsAskedAbout() {
        let one = png + [1, 2, 3, 0x0A, 0x69, 0x63, 0x6F, 0x6E], two = png + [9]
        let icons = GuestApps.parseIcons(stream([("a", one), ("b", two)]), for: ["a", "b", "c"])
        XCTAssertEqual(icons, ["a": Data(one), "b": Data(two)], "bytes that look like a line are an icon's bytes")
        XCTAssertEqual(GuestApps.parseIcons(stream([]), for: ["a"]), [:])
    }

    /// What does not fit is left out, and what came whole before it is kept: a program without an icon is still a program.
    func testIconsThatDoNotFitAreLeftOut() {
        let good = png + [1]
        XCTAssertEqual(GuestApps.parseIcons(stream([("a", good), ("zz", good)]), for: ["a"]), ["a": Data(good)], "one nobody asked for")
        XCTAssertEqual(GuestApps.parseIcons(stream([("a", [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 0, 0]), ("b", good)]), for: ["a", "b"]),
                       ["b": Data(good)], "what is no PNG is passed over")
        XCTAssertEqual(GuestApps.parseIcons(stream([("a", good), ("a", png + [2])]), for: ["a"]), ["a": Data(good)], "the first of two")
        // Cut short (the output was more than is kept): the whole ones before it.
        var cut = stream([("a", good), ("b", png + [UInt8](repeating: 7, count: 100))])
        cut.removeLast(60)
        XCTAssertEqual(GuestApps.parseIcons(cut, for: ["a", "b"]), ["a": Data(good)])
        // A size that is none, or more than an icon is: nothing after it can be told from its bytes.
        var huge = Data("icon a \(GuestApps.maxIconBytes + 1)\n".utf8)
        huge.append(Data(count: 64))
        XCTAssertEqual(GuestApps.parseIcons(huge, for: ["a"]), [:])
        for header in ["icon a -1\n", "icon a 0x10\n", "icon a\n", "icon a 5 6\n", "picture a 9\n", "icon a 09\n"] {
            var data = Data(header.utf8)
            data.append(contentsOf: good)
            XCTAssertEqual(GuestApps.parseIcons(data, for: ["a"]), [:], header)
        }
        XCTAssertEqual(GuestApps.parseIcons(Data(repeating: 0x69, count: 5000), for: ["a"]), [:], "a line that never ends")
    }

    /// Starting a program names it by its id, which is nothing but an id: no word of the guest's reaches a shell.
    func testAProgramIsStartedByAnIDThatIsOnlyAnID() {
        XCTAssertEqual(GuestApps.launchCommand("org.gnome.Calculator"), "/usr/local/lib/monad/apps launch org.gnome.Calculator")
        for bad in ["", "a b", "a;reboot", "$(reboot)", "a'b", "../x", ".x", "-x", "a/b", String(repeating: "a", count: 129), "caf\u{e9}"] {
            XCTAssertNil(GuestApps.launchCommand(bad), bad)
            XCTAssertFalse(GuestApps.isID(bad), bad)
        }
        XCTAssertEqual(GuestApps.iconsCommand(["a", "b.c"]), "/usr/local/lib/monad/apps icons a b.c")
        XCTAssertNil(GuestApps.iconsCommand(["a", "b c"]))
        XCTAssertNil(GuestApps.iconsCommand([]))
    }

    /// The icon's file on the Mac is named by the id, in the VM's own folder and nowhere else.
    func testAnIconsFileIsInTheVMsFolder() {
        let folder = URL(fileURLWithPath: "/Users/dev/.monad/instances/box/app-icons")
        XCTAssertEqual(GuestApps.iconFile("org.gnome.Calculator", in: folder)?.path, folder.path + "/org.gnome.Calculator.png")
        XCTAssertNil(GuestApps.iconFile("../../x", in: folder))
        XCTAssertNil(GuestApps.iconFile(".", in: folder))
    }

    private let some = [GuestApp(id: "org.gnome.TextEditor", name: "Text Editor"), GuestApp(id: "foot", name: "foot"),
                        GuestApp(id: "org.gnome.Calculator", name: "Calculator"), GuestApp(id: "cafe", name: "Café")]

    /// The Apps menu: the user's favourites first, each list by name.
    func testFavouritesComeFirstAndEachListIsByName() {
        var lists = GuestApps.arrange(some, favorites: [])
        XCTAssertTrue(lists.favorites.isEmpty)
        XCTAssertEqual(lists.others.map(\.name), ["Café", "Calculator", "foot", "Text Editor"], "as a person sorts, capitals or not")
        lists = GuestApps.arrange(some, favorites: ["foot", "org.gnome.Calculator", "gone"])
        XCTAssertEqual(lists.favorites.map(\.name), ["Calculator", "foot"], "a favourite that is no longer installed is not shown")
        XCTAssertEqual(lists.others.map(\.name), ["Café", "Text Editor"])
    }

    /// Searching: every word typed is in the name or the id, capitals and accents aside.
    func testSearchingFindsByNameAndID() {
        func found(_ text: String) -> [String] {
            let lists = GuestApps.arrange(some, favorites: ["foot"], matching: text)
            return (lists.favorites + lists.others).map(\.name)
        }
        XCTAssertEqual(found("calc"), ["Calculator"])
        XCTAssertEqual(found("CAFE"), ["Café"])
        XCTAssertEqual(found("gnome"), ["Calculator", "Text Editor"], "by what its id says too")
        XCTAssertEqual(found("gnome edit"), ["Text Editor"], "every word")
        XCTAssertEqual(found("  "), ["foot", "Café", "Calculator", "Text Editor"], "nothing typed: all, favourites first")
        XCTAssertEqual(found("zzz"), [])
    }

    /// Favourites are the app's own, kept by VM: starring is remembered, and bounded.
    func testFavouritesAreKeptByVM() throws {
        let suite = "GuestAppsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = GuestAppFavorites(defaults: defaults)
        XCTAssertEqual(favorites.ids(for: "web"), [])
        favorites.set("foot", starred: true, for: "web")
        favorites.set("org.gnome.Calculator", starred: true, for: "web")
        favorites.set("foot", starred: true, for: "web")
        favorites.set("foot", starred: true, for: "db")
        XCTAssertEqual(favorites.ids(for: "web"), ["foot", "org.gnome.Calculator"])
        XCTAssertEqual(GuestAppFavorites(defaults: defaults).ids(for: "db"), ["foot"], "kept")
        favorites.set("foot", starred: false, for: "web")
        XCTAssertEqual(favorites.ids(for: "web"), ["org.gnome.Calculator"])
        favorites.set("a; b", starred: true, for: "web")
        favorites.set("x", starred: true, for: "../etc")
        XCTAssertEqual(favorites.ids(for: "web"), ["org.gnome.Calculator"], "what is no id is not kept")
        XCTAssertEqual(favorites.ids(for: "../etc"), [])
        for i in 0..<200 { favorites.set("app\(i)", starred: true, for: "web") }
        XCTAssertEqual(favorites.ids(for: "web").count, GuestAppFavorites.maxPerVM)
        // What something else wrote there is not taken for ids.
        defaults.set(["web": ["ok", "not ok", 5]], forKey: GuestAppFavorites.key)
        XCTAssertEqual(favorites.ids(for: "web"), ["ok"])
    }
}
