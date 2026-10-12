import AppKit
import PeekCore

/// Builds the whole menu bar in code (no XIBs). Items with a `nil` target are
/// delivered through the responder chain to `MainWindowController`.
enum MenuBuilder {

    static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(appSubmenu())
        menu.addItem(fileSubmenu())
        menu.addItem(viewSubmenu())
        let windowItem = windowSubmenu()
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowItem.submenu
        menu.addItem(helpSubmenu())
        return menu
    }

    private static func appSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        item.submenu = menu
        menu.addItem(make("关于 \(Peek.appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(make("退出 \(Peek.appName)", #selector(NSApplication.terminate(_:)), "q"))
        return item
    }

    private static func fileSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "文件")
        item.submenu = menu
        menu.addItem(make("打开…", #selector(MainWindowController.openDocument(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(make("在 Finder 中显示", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(make("拷贝图片", #selector(MainWindowController.copyImage(_:)), "c"))
        menu.addItem(make("拷贝文件路径", #selector(MainWindowController.copyFilePath(_:)), "c", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(make("关闭窗口", #selector(NSWindow.performClose(_:)), "w"))
        return item
    }

    private static func viewSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "显示")
        item.submenu = menu

        // Arrow-key equivalents use the private-use function-key scalars.
        menu.addItem(make("上一张", #selector(MainWindowController.previousImage(_:)), "\u{F702}", []))
        menu.addItem(make("下一张", #selector(MainWindowController.nextImage(_:)), "\u{F703}", []))
        menu.addItem(make("第一张", #selector(MainWindowController.firstImage(_:)), "\u{F729}", []))
        menu.addItem(make("最后一张", #selector(MainWindowController.lastImage(_:)), "\u{F72B}", []))
        menu.addItem(.separator())

        let sortItem = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "排序方式")
        sortItem.submenu = sortMenu
        for key in ImageSortKey.allCases {
            let i = make(key.displayName, #selector(MainWindowController.setSortKey(_:)))
            i.representedObject = key.rawValue
            sortMenu.addItem(i)
        }
        sortMenu.addItem(.separator())
        let asc = make("升序", #selector(MainWindowController.setSortAscending(_:)))
        asc.representedObject = true
        let desc = make("降序", #selector(MainWindowController.setSortAscending(_:)))
        desc.representedObject = false
        sortMenu.addItem(asc)
        sortMenu.addItem(desc)
        menu.addItem(sortItem)

        return item
    }

    private static func windowSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        item.submenu = menu
        menu.addItem(make("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(make("缩放", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(make("全部带到最前面", #selector(NSApplication.arrangeInFront(_:))))
        return item
    }

    private static func helpSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "帮助")
        item.submenu = menu
        menu.addItem(make("\(Peek.appName) 使用帮助", #selector(MainWindowController.showHelp(_:)), "?"))
        return item
    }

    private static func make(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
