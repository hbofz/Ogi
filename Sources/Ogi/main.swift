import AppKit
import OgiCore

// Unbuffered: the M0 probe writes to a log and its output must arrive immediately.
setbuf(stdout, nil)

let app = NSApplication.shared
let delegate = OgiApp()
app.delegate = delegate
app.run()
