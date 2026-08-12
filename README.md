<h1 align="center">Ogi</h1>

<p align="center">
  <b>A cat that lives in your notch and treats your windows as terrain.</b>
</p>

<p align="center">
  <img src="docs/ogi-hero.gif" width="820" alt="Ogi stepping down onto a window's title bar, leaping the gap to another window, being petted, and sitting at a laptop during a call">
</p>

<p align="center">
  <sub>Real screen recording: he steps down onto a window, leaps the gap to another, gets
  petted, and joins a call.</sub>
</p>

<p align="center">
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <a href="https://github.com/hbofz/Ogi/releases/latest"><img src="https://img.shields.io/github/v/release/hbofz/Ogi" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/permissions-none-brightgreen" alt="No permissions">
</p>

---

Ogi walks along the top edges of your open windows, jumps between them, and falls when you close
the one he was standing on. He goes **behind** windows that are in front of him, which nothing
else on any platform does.

He asks for no permissions, has no settings, no account, and no network. He reads the position
and size of your windows, never their titles and never their pixels. He is just there.

## Install

Download the latest `Ogi-<version>.zip` from
[**Releases**](https://github.com/hbofz/Ogi/releases/latest), unzip it, and drag `Ogi.app` to
`/Applications`.

macOS blocks the first launch, because Ogi is signed but not notarised (that needs a paid Apple
Developer account, and there isn't one yet). Three steps, and the first one is not optional:

1. **Open `Ogi.app`.** It will refuse, and say it cannot be opened. Do it anyway: the button in
   step 2 does not exist until macOS has blocked it once, and it expires about an hour later.
2. **System Settings → Privacy & Security**, scroll down to the message about Ogi, and click
   **Open Anyway**. Authenticate when asked.
3. **Open it again** and confirm at the last dialog. That is the one that sticks.

Or, in a terminal, instead of all three:
`xattr -dr com.apple.quarantine /Applications/Ogi.app`

> Being suspicious of an app that asks you to do that is the right instinct. The source is all
> here, and `./release.sh 1.1.1` builds the same bundle from it.

**To quit, click the cat in your menu bar.** There is no Dock icon by design, so that icon is
the only way out: if your menu bar is full and macOS has hidden it, `killall Ogi` in a terminal
does the same thing.

## What he does

**He treats your desktop as terrain.** Window edges are ledges. He steps across small gaps,
jumps ones he can reach, stops at a drop to lean over and look down before committing, and
climbs the face of a window to get back up. Close the window under him and he falls.

**He notices your machine.** Plug in the charger and he is comically electrocuted. Connect
AirPods and he grooves. Run the battery low and he powers down flat. When your microphone goes
live he puts on a headset; when your camera goes live he sits at a tiny laptop and works. (The
two battery reactions need a battery, so on a desktop Mac they never fire.)

**The notch is his house.** He walks out of it at launch, walks *through* it to cross the menu
bar, hangs off its lower lip doing pull-ups, and sleeps inside it with only his tail showing.
**This part needs a notch**, so a 2021-or-later MacBook Pro or a 2022-or-later Air. Anywhere
else he lives on the menu bar instead and the three den animations do not play. Everything
above still does.

<img src="docs/ogi-petted.gif" width="110" align="right" alt="Ogi being petted">

**You can pet him.** Move your cursor across his body and he shuts his eyes, pushes his head up
into your hand, and **purrs through your trackpad** using haptic feedback. A purr you can
physically feel, on any Mac with a Force Touch trackpad. With a mouse, or on a desktop, you
still get the cat; you just don't feel him.

**[Every animation is documented](docs/animations.md)** — all 32 of them, playing, with what
each one is for.

**He costs nothing.** 0.0% CPU when idle, measured. Once he settles, the display link stops
outright and he wakes once a second to check whether you are back. The battery cost of a desktop
pet is processor wakeups, not pixels. The one exception is asleep inside the notch, where his
tail is the whole animation, so that keeps a five-a-second clock rather than freezing mid-sway.

## Build from source

Requires macOS 14+ and a Swift 6 toolchain.

```sh
git clone https://github.com/hbofz/Ogi.git && cd Ogi
./run.sh
```

That builds a debug, this-machine-only bundle and launches it, which is all you need to work on
him.

```sh
swift test          # 367 tests; the world model and physics are pure functions
./release.sh 1.1.1  # builds, tests, bundles and zips a release
```

`release.sh` needs a **full Xcode**, not just the Command Line Tools: a release is built for
Intel and Apple Silicon together, and that routes through XCBuild, which only ships inside
Xcode.app. Plain `swift build` and `swift test` are fine with the Command Line Tools alone.

The suite is deterministic. The behavioural tests still roll dice, but every roll comes from a
seeded generator, so the same commit gives the same answer every run and a red suite means you
broke something. `OGI_SEED=n` pins the running app's chance too, so he makes the same
decisions in the same order; his exact positions still drift a point or two, because the real
frame timing does.

Some of what was learned building this is written up in
[docs/macos-notes.md](docs/macos-notes.md) — most of it is either undocumented or widely
misremembered.

## Uninstall

Quit from the menu bar and delete the app. Ogi writes nothing outside itself, creates no
preferences, and installs no login item, agent, or helper.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md). Source-available, not open source.

## Contributing

**Bug reports are the most useful thing you can send**, and they need nothing from you but the
report. Code contributions need a copyright assignment first, and
[CONTRIBUTING.md](CONTRIBUTING.md) explains exactly why rather than leaving you to guess.
