import AppKit
import SwiftUI

@main
struct BubblegumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Bubblegum", id: "main") {
            ContentView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.settings)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            AppCommands(store: appDelegate.store, settings: appDelegate.settings)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.settings)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var store = SessionStore()
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare executable (`swift run`); a no-op inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Without a bundle (e.g. Run in Xcode) there is no AppIcon; use the drawn one for the Dock.
        if Bundle.main.bundleURL.pathExtension != "app" { NSApp.applicationIconImage = BubblegumIcon.image(size: 512) }
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyAppAppearance()
        store.start()
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        DebugSnapshot.runIfRequested(store: store, settings: settings)
        #endif

        // ⌘= is the unshifted key for ⌘+ on most layouts; treat it as "Bigger".
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, event.charactersIgnoringModifiers == "=" {
                self?.settings.increaseFont()
                return nil
            }
            return event
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.appDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Default quit behavior: end all claude processes; they resume via --resume next time.
        store.shutdown()
    }
}
