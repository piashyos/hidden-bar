import AppKit
import ApplicationServices
import SwiftUI

// macOS 27: приватный MenuBarClientCore, ограничение строки меню из «режима экзамена».
// Оставляет только перечисленные приложения, остальные значки система убирает сама — без «».
// Пока процесс жив и держит assertion; при выходе/падении macOS возвращает всё сама.
@objc protocol MBAssessmentModeAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(_ configuration: AnyObject, completionHandler: @escaping @Sendable (NSError?) -> Void)
    func invalidate()
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var hidden = false
    private var restriction: MBAssessmentModeAssertion?
    private var awaySince: Date?
    private var hoverTimer: Timer?
    private var settingsWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // без иконки в Dock
        app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        toggle.autosaveName = "toggle" // macOS запомнит позицию
        if let button = toggle.button {
            button.target = self
            button.action = #selector(click)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        updateIcon()
    }

    @objc private func click() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { setHidden(!hidden) }
    }

    // повторный запуск (Finder, `open`) открывает настройки — запасной путь к ним без правого клика
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    // Прячем приложения, чьи значки левее шеврона. Позиции читаются через Accessibility
    // и только в открытом состоянии: у скрытых значков рамки устаревшие.
    private func setHidden(_ value: Bool) {
        stopHover()
        hidden = value
        updateIcon()
        guard value else { restriction?.invalidate(); restriction = nil; return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary),
              let chevron = toggle.button?.window?.frame else { return failOpen() }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            guard app.processIdentifier != me, app.bundleURL?.pathExtension == "app",
                  let id = app.bundleIdentifier else { return nil }
            return (app.processIdentifier, id)
        }
        Task {
            let items = await Task.detached { Self.statusItems(of: apps) }.value
            guard hidden, restriction == nil else { return } // пока читали, успели раскрыть или уже спрятали
            let boundary = fromRightEdge(chevron)
            let keep = Set(items.filter { fromRightEdge($0.frame) < boundary }.map(\.bundle))
            restrict(to: [Bundle.main.bundleIdentifier].compactMap { $0 } + keep)
        }
    }

    // ponytail: приватный API — если Apple его поменяет, скрытие не сработает (бип), значки останутся на месте.
    // Скрытие поприложенческое: у приложения с несколькими значками все прячутся/остаются вместе.
    private func restrict(to bundles: [String]) {
        let initSel = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        guard dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != nil,
              let configClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              configClass.instancesRespond(to: initSel),
              assertionClass.instancesRespond(to: #selector(MBAssessmentModeAssertion.activate(_:completionHandler:))),
              assertionClass.instancesRespond(to: #selector(MBAssessmentModeAssertion.invalidate))
        else { return failOpen() }
        // системные значки (часы, Wi-Fi, Пункт управления…) — по номерам; неизвестные номера игнорируются
        let systemItems = (0..<64).map { NSNumber(value: $0) } as NSArray
        let config = configClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            .perform(initSel, with: systemItems, with: bundles as NSArray).takeRetainedValue()
        let assertion = unsafeBitCast(assertionClass.init(), to: MBAssessmentModeAssertion.self)
        restriction = assertion
        let id = ObjectIdentifier(assertion)
        assertion.activate(config) { error in
            guard let error else { return }
            NSLog("HiddenBar: скрытие не удалось: \(error.localizedDescription)")
            Task { @MainActor in if self.restriction.map(ObjectIdentifier.init) == id { self.failOpen() } }
        }
    }

    private func failOpen() {
        restriction?.invalidate()
        restriction = nil
        hidden = false
        updateIcon()
        NSSound.beep()
    }

    // Значки других приложений в координатах CG (начало сверху слева). ~1 с на все приложения, поэтому не на главном.
    nonisolated private static func statusItems(of apps: [(pid_t, String)]) -> [(bundle: String, frame: CGRect)] {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        var items: [(String, CGRect)] = []
        for (pid, bundle) in apps {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1) // зависшее приложение иначе держит секундами
            guard let bar = attribute(app, "AXExtrasMenuBar"),
                  let children = attribute(bar as! AXUIElement, "AXChildren") as? [AXUIElement] else { continue }
            for child in children {
                guard let p = attribute(child, "AXPosition"), let s = attribute(child, "AXSize") else { continue }
                var origin = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &origin)
                AXValueGetValue(s as! AXValue, .cgSize, &size)
                let top = NSScreen.screens.first?.frame.height ?? 0 // CG → Cocoa: y от низа главного дисплея
                items.append((bundle, CGRect(x: origin.x, y: top - origin.y - size.height, width: size.width, height: size.height)))
            }
        }
        return items
    }

    // Расстояние от правого края своего дисплея: правая часть строки меню одинакова на всех дисплеях,
    // а рамки шеврона и чужих значков могут прийти с разных (у тебя дисплеи друг над другом, x перекрываются).
    private func fromRightEdge(_ r: CGRect) -> CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }
        return screen.map { $0.frame.maxX - r.midX } ?? 0 // вне дисплеев → считаем правее шеврона, не прячем
    }

    // MARK: наведение

    // AppDelegate не NSResponder: без явного имени Swift даст селектор mouseEnteredWith:,
    // а NSTrackingArea шлёт mouseEntered: — исключение «unrecognized selector», наведение молча не работает
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard hidden, UserDefaults.standard.bool(forKey: "revealOnHover") else { return }
        setHidden(false)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { self.rehideIfAway() }
        }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {}

    // Прячем снова, когда курсор ~1 с вне строки меню и не открыто ничьё меню.
    private func rehideIfAway() {
        let p = NSEvent.mouseLocation
        let inBar = NSScreen.screens.contains {
            p.x >= $0.frame.minX && p.x <= $0.frame.maxX && p.y >= $0.visibleFrame.maxY && p.y <= $0.frame.maxY
        }
        if inBar || menuIsOpen() { awaySince = nil; return }
        guard let since = awaySince else { awaySince = Date(); return }
        if Date().timeIntervalSince(since) > 1 { setHidden(true) }
    }

    // ponytail: ловит только NSMenu; поповеры чужих значков не видны, их спасает лишь задержка в 1 с
    private func menuIsOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { $0[kCGWindowLayer as String] as? Int == level }
    }

    private func stopHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        awaySince = nil
    }

    // MARK: меню и настройки

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggle.menu = menu
        toggle.button?.performClick(nil) // показывает меню синхронно
        toggle.menu = nil
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "HiddenBar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateIcon() {
        toggle.button?.image = NSImage(
            systemSymbolName: hidden ? "chevron.left" : "chevron.right",
            accessibilityDescription: nil)
    }
}

struct SettingsView: View {
    @AppStorage("revealOnHover") private var revealOnHover = false

    var body: some View {
        Form {
            Picker("Показывать скрытые значки:", selection: $revealOnHover) {
                Text("по нажатию на шеврон").tag(false)
                Text("при наведении на шеврон").tag(true)
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .fixedSize()
    }
}
