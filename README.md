# Ogi

**A cat that lives in your notch and treats your windows as terrain.**

Ogi walks along the top edges of your open windows, jumps between them, and falls when you
close the one he is standing on. He goes *behind* windows that are in front of him. He notices
your battery, your microphone, and how long you have been working without a break.

He asks nothing of you, ever, and there is nothing to manage.

- [MANIFESTO.md](MANIFESTO.md) — what he is, and why
- [ROADMAP.md](ROADMAP.md) — what works, what doesn't, and what is being built next
- [docs/DESIGN.md](docs/DESIGN.md) — architecture, and the research behind every decision

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

## Status: built, and not yet watched

He walks your window edges and he walks *off* them. Given a desktop with windows on it he
works his way down: stepping across a gap that is small enough, jumping one he can reach,
stepping off a ledge onto whatever is below, and deciding again the moment he lands. At a drop
he stops at the lip, leans over it, looks down, holds there, and then either commits or backs
off and goes somewhere else instead. Set him down on the face of a window and he clings to it,
holds, then climbs onto the ledge above him or slides down it. He comes out of the notch at
launch and goes back into it when you quit. He turns on the spot instead of flipping, and
shakes himself off after a hard landing.

He still **goes behind windows that are in front of him**, which nothing else on any platform
does. He still falls when you close the window under him. He settles when you stop typing, and
freezes when your microphone goes live.

Set him down on a window's face and he **grabs it and climbs**, whatever your cursor was doing
at the time. He can climb to get back up, too: jump at a face, catch it on the way past, and
haul himself onto the ledge. He will not grab a face he is *falling* past, which is deliberate,
because catching every fall at the first window would kill the fall.

It is covered by 169 unit tests and by simulation (the descent was soaked at 400 runs of 600
seconds, and he was stranded in none of them). The first pass was tuned entirely against that
simulation; watching him for fifteen minutes then corrected four things it could not see, and
more of it will need the same. He also still lives on one display: he survives a monitor being
plugged in, unplugged, or rearranged, and he survives a Space change, but he does not cross to
another screen.

He is a ginger tabby, drawn across 79 frames in seventeen animations. Cursor-tracking eyes are
built and currently switched off: painting a live pupil needs an empty socket in the artwork,
and the drawn frames have the eye complete. See `docs/ART-BRIEF.md`.

**Idle cost: 0.0% CPU, measured.** Once he is asleep the display link is stopped outright and
he watches for your return once a second. The battery cost of a desktop pet is processor
wakeups rather than pixels (the best-known offender in this category draws complaints at four
wakeups a second), so when he has nothing to do he does nothing, rather than redrawing an
unchanged cat sixty times a second.

See [ROADMAP.md](ROADMAP.md) for what is left, and for what did not land.

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

Not yet decided. No licence is granted until one is added here.
