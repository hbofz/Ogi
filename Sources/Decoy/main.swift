import AppKit
setbuf(stdout, nil)

// ponytail: 20-line test fixture, not product code. The fall is THE behaviour of this app
// and testing it by closing the user's real windows is both destructive and unrepeatable.
// This opens a window Ogi can perch on, then vanishes on SIGTERM.
let app = NSApplication.shared
app.setActivationPolicy(.regular)   // .accessory apps cannot enter fullscreen

let rect = NSRect(x: 60, y: 300, width: 380, height: 400)   // top edge y=700, clear of other windows
let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                 backing: .buffered, defer: false)
w.title = "decoy"
w.backgroundColor = .systemPink
w.orderFrontRegardless()
print("[decoy] window up at \(rect), top edge y=\(rect.maxY)")

// Lets the harness test the flakiest interaction in the app: does a level-25 overlay
// with .fullScreenAuxiliary still draw over another app's fullscreen Space?
if let after = ProcessInfo.processInfo.environment["DECOY_FULLSCREEN_AFTER"].flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
        print("[decoy] going fullscreen")
        w.toggleFullScreen(nil)
    }
}

app.run()
