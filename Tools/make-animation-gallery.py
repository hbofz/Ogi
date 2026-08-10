#!/usr/bin/env python3
"""Renders every animation to a GIF and writes docs/animations.md around them.

Generated rather than hand-maintained, and the frame counts and rates are parsed out of
`Sprites.swift` rather than typed here, so a sheet that gains a frame or changes speed cannot
leave this page quietly wrong. Run it after installing any new clip:

    python3 Tools/make-animation-gallery.py

Needs ffmpeg (brew install ffmpeg).
"""
import os, re, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPRITES = os.path.join(REPO, "Sources/OgiCore/Resources/Sprites")
OUT_DIR = os.path.join(REPO, "docs/clips")
SWIFT = os.path.join(REPO, "Sources/OgiCore/Sprites.swift")
HEIGHT = 110

# What each clip is FOR. The one thing here that cannot be parsed out of the source, and the
# only reason this page is worth more than a directory listing.
WHEN = {
    "walk":     "Getting somewhere along a ledge.",
    "run":      "The same, in a hurry: a long way to go, and not feeling sluggish.",
    "jump":     "The crouch and the launch. Also every airborne frame.",
    "fall":     "The righting reflex. Plays whether he was dropped or his window vanished.",
    "land":     "Touching down. Doubles as the pull-up when he mantles onto a ledge.",
    "shake":    "Shaking it off after a landing hard enough to rattle him.",
    "turn":     "Pivoting on the spot rather than flipping, which reads as a glitch.",
    "cling":    "Gripping a vertical window face, deciding whether to go up or slide down.",
    "climbUp":  "Going up one on purpose. The only route off the desktop.",
    "idle":     "Standing about. Breathing, and almost nothing else.",
    "sitdown":  "Settling, when the room has been quiet for a while.",
    "curl":     "Curling up. Ends on the sleeping pose and holds it.",
    "sleep":    "Asleep. The display link is stopped underneath this; he costs nothing.",
    "lounge":   "Sprawled flat, head up, watching the room. What a bare desktop gets.",
    "groom":    "Washing. The commonest thing he does out of boredom.",
    "stretch":  "The wake-up bow and yawn. Every wake, unlock and plug-in.",
    "alert":    "Frozen and listening. Your microphone went live, or you are typing hard.",
    "lookDown": "Head over the lip of a drop, deciding whether to commit.",
    "peek":     "Creeping out of the notch, low and cautious. Also how he waits in its doorway.",
    "peer":     "Head and paws over the top edge of the window that was hiding him.",
    "denSleep": "Asleep inside the notch. All you can see is a tail below the bar line.",
    "hang":     "Hanging off the notch's lower lip by his front paws, doing reps.",
    "peerDown": "Lying in the notch, head over its lower lip, watching you.",
    "zap":      "Comically electrocuted. The charger just went in.",
    "vibe":     "Grooving. An audio device connected — your AirPods are in.",
    "droop":    "Powering down flat. The battery just crossed properly low.",
    "curious":  "A head-tilt at a question mark. Something arrived on the cable.",
    "callTalk": "On a call with a boom mic: your microphone is live and your camera is not.",
    "callWork": "At a tiny laptop, typing: your camera is live and your microphone is not.",
    "callFull": "Both, which is what a real call looks like.",
    "held":     "Dangling by the scruff, limp, legs tucked. This is what actually happens to cats.",
    "stroked":  "Eyes shut, head pushed up into your hand, and the trackpad purring.",
}

GROUPS = [
    ("Moving", "Everything that gets him from one place to another. Windows are terrain, and\n"
               "their top edges are ledges.",
     ["walk", "run", "jump", "fall", "land", "shake", "turn", "cling", "climbUp"]),
    ("Resting", "Where he spends most of his life. The failure mode of all of these is animating\n"
                "too much, so several move by two or three pixels and no more.",
     ["idle", "sitdown", "curl", "sleep", "lounge", "groom", "stretch"]),
    ("Looking at things", "Noticing is half of what makes something read as alive.",
     ["alert", "lookDown", "peek", "peer"]),
    ("The notch", "His house. Nothing renders behind a hardware cutout, which is the whole\n"
                  "design constraint of these three and the reason none of them can be screenshotted.",
     ["denSleep", "hang", "peerDown"]),
    ("Your machine", "Performances, each triggered by something real happening to your Mac.",
     ["zap", "vibe", "droop", "curious", "callTalk", "callWork", "callFull"]),
    ("Touching him", "The two things you can do to him directly.",
     ["held", "stroked"]),
]


def parse_switch(src, header, computed=None):
    """Pulls `case .a, .b: value` out of one switch body in Sprites.swift."""
    start = src.index(header)
    depth, i, body = 0, start, []
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                break
        body.append(src[i])
        i += 1
    out = {}
    for names, value in re.findall(r"case ([^:\n]+):\s*([^\n/]+)", "".join(body)):
        v = value.strip()
        for n in names.split(","):
            n = n.strip().lstrip(".")
            if n.isidentifier():
                out[n] = v
    if computed:
        out.update(computed)
    return out


def looping_clips(src):
    """The `case ...: true` arm of the loops switch, and only that arm.

    Comments are stripped first. The switch is preceded by a dozen lines explaining why each
    clip loops, and those sentences are full of clip names — reading the block whole reports
    `walk` and `run` as non-looping, which is visibly wrong on the page.
    """
    body = src[src.index("var loops: Bool {"):]
    body = body[:body.index("var footAnchor") if "var footAnchor" in body else 3000]
    body = "\n".join(re.sub(r"//.*", "", line) for line in body.splitlines())
    m = re.search(r"case\s+((?:\s*\.\w+\s*,?)+)\s*:\s*true", body)
    return set(re.findall(r"\.(\w+)", m.group(1))) if m else set()


def main():
    src = open(SWIFT).read()
    counts = {k: int(v) for k, v in parse_switch(src, "var count: Int {").items() if v.isdigit()}
    # climbUp's rate is derived from the climb speed so it cannot drift from it; the formula is
    # clingClimbSpeed / climbStride * 6, which is 110 / 55 * 6.
    fps = parse_switch(src, "var fps: Double {", computed={"climbUp": "12"})
    fps = {k: float(v) for k, v in fps.items() if re.fullmatch(r"[\d.]+", v)}
    loops = looping_clips(src)

    os.makedirs(OUT_DIR, exist_ok=True)
    listed = {c for _, _, cs in GROUPS for c in cs}
    missing = set(counts) - listed
    if missing:
        print(f"warning: not in any group, so not on the page: {sorted(missing)}", file=sys.stderr)

    lines = ["# Every animation",
             "",
             f"All {len(counts)} of them, at the rate the app actually plays them. Generated by",
             "`Tools/make-animation-gallery.py` straight from the shipped sprites, so it cannot",
             "drift from what he really does.",
             ""]

    for title, blurb, clips in GROUPS:
        lines += [f"## {title}", "", blurb, "",
                  "| | Clip | Frames | Rate | When |", "|---|---|---|---|---|"]
        for clip in clips:
            n, rate = counts.get(clip), fps.get(clip)
            if n is None or rate is None:
                print(f"warning: {clip} not found in Sprites.swift", file=sys.stderr)
                continue
            gif = f"{clip}.gif"
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(rate),
                 "-i", os.path.join(SPRITES, f"{clip}%d.png"),
                 "-vf", f"scale=-1:{HEIGHT}:flags=lanczos,split[s0][s1];"
                        "[s0]palettegen=reserve_transparent=1[p];[s1][p]paletteuse=alpha_threshold=128",
                 "-loop", "0", os.path.join(OUT_DIR, gif)], check=True)
            held = "" if clip in loops else " (holds its last frame)"
            lines.append(f'| <img src="clips/{gif}" height="{HEIGHT}"> | `{clip}` | {n} | '
                         f"{rate:g}fps{held} | {WHEN.get(clip, '')} |")
        lines.append("")

    lines += ["---", "",
              "Drawn as green-screen sheets, one animation to a row, and cut into transparent",
              "frames by `Tools/extract-sprites.swift`. Every clip is normalised on the width of",
              "his eye so that sheets generated weeks apart still render the same cat — except the",
              "handful whose eyes cannot be measured, which carry their own height instead.", ""]

    with open(os.path.join(REPO, "docs/animations.md"), "w") as f:
        f.write("\n".join(lines))
    print(f"wrote docs/animations.md and {len(listed)} gifs into docs/clips/")


if __name__ == "__main__":
    main()
