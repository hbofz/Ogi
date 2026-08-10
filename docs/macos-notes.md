# Notes from building Ogi

Verified on macOS 26.5.1. Most of this is either undocumented or widely misremembered, and all
of it cost time to find out.

### `CGWindowListCopyWindowInfo` is not deprecated

Its imaging sibling `CGWindowListCreateImage` was obsoleted in macOS 15, and the two get
conflated constantly. Window geometry and stacking order cost no permission at all; only
`kCGWindowName` is gated behind Screen Recording.

### Reading the window list is cheap

**298 µs** with 19 windows open, so a 10 Hz world poll is about 0.3% of one core. Terrain that
lags behind your windows is a choice, not a constraint.

### Per-pixel alpha click-through is broken

On macOS 26.5.1, transparent regions of a borderless window intercept clicks instead of passing
them through. Ogi drives `ignoresMouseEvents` from the cursor position instead, so he only
swallows a click when the pointer is actually on him.

### The Dock owns two windows

The Dock process owns a **full-screen layer-20 window** as well as the visible Dock. Identifying
the Dock by owner and layer alone finds the wrong one. This caused three separate bugs here.

### Native fullscreen recreates the window

Entering fullscreen gives the window a new ID. Ogi reads that as his world vanishing, and falls.
That is the intended behaviour, and it is also why a fullscreen app reads as a covered screen.

### Drawing above another app's fullscreen Space

A level-25 panel with `.fullScreenAuxiliary` and `.canJoinAllSpaces` still draws over another
app's fullscreen Space.

### The microphone is permanently hot on most Macs

`com.apple.CoreSpeech`, the always-on "Hey Siri" listener, holds a running audio input
**continuously**. Any per-process microphone check is therefore true forever on a Mac with Siri
enabled, unless you filter that bundle ID out.

The obvious fix is worse than the bug: `kAudioDevicePropertyDeviceIsRunningSomewhere` gets this
case right but always reports false for **Bluetooth** microphones, which would silently break
the signal for everyone who takes calls on AirPods.

### A screenshot cannot show the notch

`screencapture` fills the hardware cutout with wallpaper, so anything drawn in or around the
notch has to be verified with a camera or with your own eyes.

### SwiftPM resources live outside your binary

`swift build` emits a package's resources as a separate `.bundle` beside the executable, not
inside it. Copy only the binary into an `.app` and it will run perfectly on your machine and
draw nothing on anyone else's, because the generated `Bundle.module` accessor falls back to the
absolute build path — which exists only where it was built.
