import AppKit
import FlickCore

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
        menu.addItem(make(L10n.s("About \(Flick.appName)", "关于 \(Flick.appName)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(make(L10n.s("Quit \(Flick.appName)", "退出 \(Flick.appName)"), #selector(NSApplication.terminate(_:)), "q"))
        return item
    }

    private static func fileSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.s("File", "文件"))
        item.submenu = menu
        menu.addItem(make(L10n.s("Open…", "打开…"), #selector(MainWindowController.openDocument(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(make(L10n.s("Reveal in Finder", "在 Finder 中显示"), #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(make(L10n.s("Copy Image", "拷贝图片"), #selector(MainWindowController.copyImage(_:)), "c"))
        menu.addItem(make(L10n.s("Copy File Path", "拷贝文件路径"), #selector(MainWindowController.copyFilePath(_:)), "c", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(make(L10n.s("Print…", "打印…"), #selector(MainWindowController.printImage(_:)), "p"))
        menu.addItem(.separator())
        menu.addItem(make(L10n.s("Close Window", "关闭窗口"), #selector(NSWindow.performClose(_:)), "w"))
        return item
    }

    private static func viewSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.s("View", "显示"))
        item.submenu = menu

        // Arrow-key equivalents use the private-use function-key scalars.
        menu.addItem(make(L10n.s("Previous", "上一张"), #selector(MainWindowController.previousImage(_:)), "\u{F702}", []))
        menu.addItem(make(L10n.s("Next", "下一张"), #selector(MainWindowController.nextImage(_:)), "\u{F703}", []))
        menu.addItem(make(L10n.s("First", "第一张"), #selector(MainWindowController.firstImage(_:)), "\u{F729}", []))
        menu.addItem(make(L10n.s("Last", "最后一张"), #selector(MainWindowController.lastImage(_:)), "\u{F72B}", []))
        menu.addItem(.separator())

        let sortItem = NSMenuItem(title: L10n.s("Sort By", "排序方式"), action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: L10n.s("Sort By", "排序方式"))
        sortItem.submenu = sortMenu
        for key in ImageSortKey.allCases {
            let i = make(key.displayName, #selector(MainWindowController.setSortKey(_:)))
            i.representedObject = key.rawValue
            sortMenu.addItem(i)
        }
        sortMenu.addItem(.separator())
        let asc = make(L10n.s("Ascending", "升序"), #selector(MainWindowController.setSortAscending(_:)))
        asc.representedObject = true
        let desc = make(L10n.s("Descending", "降序"), #selector(MainWindowController.setSortAscending(_:)))
        desc.representedObject = false
        sortMenu.addItem(asc)
        sortMenu.addItem(desc)
        menu.addItem(sortItem)
        menu.addItem(.separator())

        menu.addItem(make(L10n.s("Zoom In", "放大"), #selector(MainWindowController.zoomIn(_:)), "="))
        menu.addItem(make(L10n.s("Zoom Out", "缩小"), #selector(MainWindowController.zoomOut(_:)), "-"))
        menu.addItem(make(L10n.s("Zoom to Fit", "适应窗口"), #selector(MainWindowController.zoomToFit(_:)), "0"))
        menu.addItem(make(L10n.s("Actual Size", "实际大小"), #selector(MainWindowController.zoomToActualSize(_:)), "1"))
        menu.addItem(make(L10n.s("Fill Window", "填满窗口"), #selector(MainWindowController.zoomToFill(_:)), "2"))
        menu.addItem(.separator())

        menu.addItem(make(L10n.s("Rotate Right", "顺时针旋转"), #selector(MainWindowController.rotateRight(_:)), "r"))
        menu.addItem(make(L10n.s("Rotate Left", "逆时针旋转"), #selector(MainWindowController.rotateLeft(_:)), "r", [.command, .shift]))
        menu.addItem(make(L10n.s("Keep Rotation Across Images", "切换图片时保持旋转角度"), #selector(MainWindowController.toggleKeepRotation(_:))))
        menu.addItem(make(L10n.s("Wrap Around", "循环浏览"), #selector(MainWindowController.toggleWrapAround(_:))))
        menu.addItem(.separator())

        menu.addItem(make(L10n.s("Pause Animation", "暂停动画"), #selector(MainWindowController.toggleAnimationPlayback(_:)), "p", []))
        menu.addItem(make(L10n.s("Info Panel", "信息面板"), #selector(MainWindowController.toggleInfoPanel(_:)), "i"))
        menu.addItem(make(L10n.s("Filmstrip", "缩略图条"), #selector(MainWindowController.toggleFilmstrip(_:)), "t", []))
        menu.addItem(.separator())

        let backgroundItem = NSMenuItem(title: L10n.s("Background", "背景"), action: nil, keyEquivalent: "")
        let backgroundMenu = NSMenu(title: L10n.s("Background", "背景"))
        backgroundItem.submenu = backgroundMenu
        for style in BackgroundStyle.allCases {
            let i = make(style.displayName, #selector(MainWindowController.setBackground(_:)))
            i.representedObject = style.rawValue
            backgroundMenu.addItem(i)
        }
        menu.addItem(backgroundItem)
        menu.addItem(.separator())

        menu.addItem(make(L10n.s("Enter Full Screen", "进入全屏"), #selector(MainWindowController.toggleFullScreen(_:)), "f", [.command, .control]))

        return item
    }

    private static func windowSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.s("Window", "窗口"))
        item.submenu = menu
        menu.addItem(make(L10n.s("Minimize", "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(make(L10n.s("Zoom", "缩放"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(make(L10n.s("Bring All to Front", "全部带到最前面"), #selector(NSApplication.arrangeInFront(_:))))
        return item
    }

    private static func helpSubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.s("Help", "帮助"))
        item.submenu = menu
        menu.addItem(make(L10n.s("\(Flick.appName) Help", "\(Flick.appName) 使用帮助"), #selector(MainWindowController.showHelp(_:)), "?"))
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
