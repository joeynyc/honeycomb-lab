import AppKit
import SwiftUI

@main
struct HoneycombApp: App {
    @State private var monitor = HealthMonitor()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("privacyMode") private var privacyMode = false

    var body: some Scene {
        WindowGroup("Honeycomb Lab", id: "main") {
            ContentView(monitor: monitor)
                .onAppear {
                    // Keep monitoring even when this window closes — the
                    // menu bar panel shows live node state for the app's
                    // whole lifetime.
                    monitor.start()
                    Self.applyDockIcon()
                }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Lab") {
                Button("Rescan Nodes") {
                    Task { await monitor.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button(privacyMode ? "Privacy Mode: On" : "Privacy Mode: Off") {
                    privacyMode.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarPanel(
                monitor: monitor,
                onOpenMain: {
                    NSApp.activate(ignoringOtherApps: true)
                    // Bring any Honeycomb window forward
                    if let win = NSApp.windows.first(where: { $0.title.contains("Honeycomb") }) {
                        win.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        // Prefer custom template image; fall back to green hex glyph
        if let img = Self.menuBarNSImage() {
            Image(nsImage: img)
        } else {
            HStack(spacing: 2) {
                Text("⬡")
                    .foregroundStyle(Color(red: 0.49, green: 1.0, blue: 0.23))
                Text("\(monitor.onlineCount)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
    }

    private static func applyDockIcon() {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

    private static func menuBarNSImage() -> NSImage? {
        // Bundle resource (SPM)
        let names = ["MenuBarIcon", "MenuBarIcon@2x"]
        for name in names {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        // Draw a tiny hex programmatically as last resort
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) * 0.38
            for i in 0..<6 {
                let a = (CGFloat(i) * 60 - 30) * .pi / 180
                let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
            NSColor.black.setStroke()
            path.lineWidth = 1.2
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
