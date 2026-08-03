# Ogi

**A cat that lives in your notch and treats your windows as terrain.**

Ogi walks along the top edges of your open windows, jumps between them, and falls when you
close the one he is standing on. He goes *behind* windows that are in front of him. He notices
your battery, your microphone, and how long you have been working without a break.

He asks nothing of you, ever, and there is nothing to manage.

See [MANIFESTO.md](MANIFESTO.md) for what he is and why.

---

## He cannot spy on you, by construction

**Ogi requests no permissions. Not one.** There is no permission prompt on first launch,
because there is nothing he could ask for that he needs.

He reads the *position and size* of your windows, never their titles and never their pixels.
Window titles would require Screen Recording permission, so we don't read them. He can feel
your typing *rhythm* through a system-wide keystroke counter that reports a number and cannot
report a key. He can tell the microphone is live without listening to it.

This is a design constraint, not an afterthought. If a feature needs a permission, it does not
ship. Two behaviours described in the manifesto were cut for exactly this reason.

There is no account, no network, no telemetry, and no backend.

---

## Status: early

Milestone 0 works. He falls.

- [x] **M0 — the fall.** Reads your real windows as terrain, obeys gravity, lands with a
      squash proportional to impact, and drops when his window closes
- [ ] M1 — occlusion (he goes behind windows in front of his perch)
- [ ] M2 — eyes that track your cursor
- [ ] M3 — walking and jumping
- [ ] M4 — surfing a dragged window
- [ ] M5 — the real silhouette (he is currently a blob with ears)
- [ ] M6 — mic, battery, idle, sleep
- [ ] M7 — pick him up and he lands on his feet
- [ ] M8 — the notch home, and the bookends

## Build and run

Requires macOS 14+ and a Swift 6 toolchain (Xcode 26).

```sh
./run.sh
```

That builds Ogi, wraps it in an app bundle, and launches it. **To quit, use the cat in your
menu bar.** There is no Dock icon by design, so that menu bar item is the way out.

```sh
swift test     # the world model and physics are pure functions, and tested as such
```

## Uninstall

Quit from the menu bar and delete the folder. Ogi writes nothing outside it, creates no
preferences, and installs no login item, agent, or helper.

## Verified on macOS 26.5.1

Notes from building this, since most of it is either undocumented or widely misremembered:

- `CGWindowListCopyWindowInfo` is **not deprecated**. Its imaging sibling
  `CGWindowListCreateImage` was obsoleted in macOS 15, and the two get conflated constantly.
  Geometry and stacking order cost no permission; only `kCGWindowName` is gated.
- Reading the window list costs **298 µs** with 19 windows, so a 10 Hz world poll is about
  0.3% of one core. Terrain that lags is a choice, not a constraint.
- **Per-pixel alpha click-through is broken on macOS 26.5.1.** Transparent regions of a
  borderless window intercept clicks instead of passing them through. Ogi drives
  `ignoresMouseEvents` from the cursor position instead, so he only swallows a click when it
  is actually on him.
- The Dock process owns a **full-screen** layer-20 window as well as the visible Dock.
  Identifying the Dock by owner and layer alone will find the wrong one.
- Entering native fullscreen **recreates** a window with a new ID. Ogi reads that as his world
  vanishing, and falls. That is the intended behaviour.
- A level-25 panel with `.fullScreenAuxiliary` and `.canJoinAllSpaces` still draws over
  another app's fullscreen Space.

## License

MIT
