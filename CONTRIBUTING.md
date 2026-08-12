# Contributing

## The short version

**Issues, bug reports, and "I watched him do something odd" are the most useful thing you can
send, and they need nothing from you but the report.** Almost every real defect in this project
was found by running it and watching, never by reading the code or by the three hundred and
fifty tests. If he does something wrong on your machine, that is genuinely valuable and I want
to hear about it.

**Pull requests containing code need a copyright assignment before they can be merged.** If you
would rather not sign one, open an issue describing the change instead. That is not a brush-off:
a well-described bug is worth more here than a patch, for the reason above.

## Why the assignment

Ogi is under [PolyForm Noncommercial](LICENSE.md), and I may relicense it in future, including
commercially.

I can only do that while I hold copyright in all of it. The moment someone else's code is merged,
they own copyright in their lines, and relicensing then requires tracking down every contributor
who ever landed a patch and getting each of them to agree in writing. Projects get permanently
stuck this way, and it is not recoverable once it happens.

So this is stated up front rather than discovered later. You are giving up something real, and
you should know that before you spend an evening on a patch, not after.

## If you do want to send code

Open an issue first so we can agree the shape of it. Then:

- `swift test` has to stay green. It is 367 tests, it runs in about twenty seconds, and it is
  **deterministic**: a red run means you broke something, not that you were unlucky. The
  behavioural tests still roll dice, but every roll comes from a seeded generator
  (`CatState.roll`), so the same commit gives the same answer every time. CI runs it on every
  push. If you add a test that samples a tendency over many trials, give each trial its own
  seed (`cat.roll = Roll(seed: UInt64(trial))`) or all your trials are one trial.
- **Watch it on the machine.** `./run.sh`, and `OGI_DEBUG=1` narrates what he is doing. Four
  separate bugs in this project survived hundreds of passing tests and were caught by somebody
  looking at the screen.
- Every physics and timing constant lives in `Sources/OgiCore/Feel.swift`, with a comment saying
  what it is for and, where it was tuned by eye, what it looked like when it was wrong. If you
  move a number, move the comment with it.
- `docs/macos-notes.md` collects the platform behaviour that cost the most time to discover.
  Worth reading before you fight the window server.

Art is not open to contribution. The sheets are generated and are not in the repository, and the
frame counts, rates and anchors in `Sprites.swift` are tied to specific ones, so a new clip means
regenerating and re-cutting rather than adding a file. `Tools/extract-sprites.swift` is the
cutter, if you want to see how frames come out of a sheet. If a clip looks wrong on your machine,
an issue with a screen recording is the right way to report it.
