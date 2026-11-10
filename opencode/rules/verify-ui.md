# Mandatory UI verification

Load this whenever your change affects anything a human sees.

## A. Verify by pixels, not by review

Text review finds crashes; it cannot find ugliness. If you can't see it, you didn't verify it.
The worker model accepts images and the read tool accepts PNGs, so:

1. Build a throwaway rig under `$DELEGATE_EVIDENCE_DIR` (durable and visible to the reviewer; NOT in the repo,
   and not under /tmp where a recreate deletes the evidence):

       mkdir -p "$DELEGATE_EVIDENCE_DIR/<task>" && cd "$DELEGATE_EVIDENCE_DIR/<task>"

   Name the subdir after the task so runs do not overwrite each other, and read the last
   screenshots from an earlier run before assuming a PNG is current.
2. Write a Node or Python script (both are in the image) that reads your artifact and emits
   one HTML variant per state, each self-driving to that state on load — e.g. for a canvas game,
   a variant that starts at `ready`, one that force-starts play, one that forces the game-over
   screen. Injecting state beats clicking. For a served app (Next.js, an API with pages), the
   variants are routes in each state instead: start the dev or production server in the
   background, put the database into each state with a seed script, and shoot each URL —
   signed-out, signed-in, empty, populated, error. Kill the server when done.

   **Exposing a seam is the cheap way to do this, so expose one.** Every run that verified
   multiple states did it through a hook the artifact itself provided (`appTest.setState`,
   `__app.die()`) — it costs a few lines and it is what makes the play and game-over variants
   trivial. Without a hook you fall back to copying the file and patching its state variables from
   outside, which also works but is brittle and burns turns on string replacement. Either is
   acceptable; unverifiable is not. Keep the hook inert unless called, and name it in the summary —
   it is not the scaffolding §3 forbids.
3. Shoot each variant with the wrapper baked into this image — it carries the flags, so do not
   hand-roll a chromium command:

       delegate-shot play.png play.html 460x760
       delegate-shot me.png http://localhost:3000/me 1280x800   # a dev server you started

   A relative output path lands under `$DELEGATE_EVIDENCE_DIR` automatically (that directory is
   already unique to this task). It writes the
   PNG plus `play.log`, which is your console-error channel. Read that log even when the
   screenshot looks fine — a page can render correctly and still throw.
4. **read each PNG** — one read call listing all of them. This step is the whole point.
5. Also shoot a narrow (360x740) and a wide (1280x800) variant. Layout bugs are viewport-specific.
6. Fix, re-shoot. Judge your own work as a reviewer would: contrast, alignment, clipped or
   overflowing text, spacing rhythm, whether the first screen reads as intentional.
7. Finish by shooting the **real artifact**, not the rig, and read that too.

Report at the end: states captured, console errors found, what you changed as a result of
looking. If `delegate-shot` or chromium is unavailable, say that sentence out loud, do section B,
and state that visual verification was unavailable.

## B. Floor when no renderer exists

Extract the script/JS and run it under node to catch syntax and load-time errors (`node --check`
at minimum). Then enumerate what you could NOT verify. Never imply you saw something you didn't.

## C. Grow the artifact; never write it in one shot.

**Chunking is enforced by the harness, not advised by this file.** `write`/`edit` payloads over
6,000 characters are rejected (`plugins/chunk-cap.js`, a letter-port of stock Cline's editor gate
— same constant, same rejection message, Cline's own schema guidance appended to the write/edit/
bash tool descriptions), so skeleton-then-grow is the only writable shape here, exactly as
it is on stock Cline. What a one-shot write physically cannot do is add a feature you did not
think of before you started typing — which is why the artifact has to be grown.

The working shape that follows from the cap:

1. Write a thin but runnable skeleton, then grow it one focused feature per call; the file must
   parse after every call. Renames, reformatting and bug fixes are not growth.
2. Sentinel comments (`// __PART_2__`) are the mechanism that keeps the skeleton honest; prove none
   leaked:

       grep -n "__PART\|__TODO__\|__GAME__" f && echo "MARKERS LEFT - FIX" || echo clean

No minimum pass count is given, deliberately: stock Cline sets none — its baseline grew its
artifact through 15 chained editor calls on zero prose about passes — and any fixed count would be
a number fitted to one benchmark task, wrong on the next one. Let the §10 enumeration decide when
the artifact is grown: if you can still name a feature from it that is not in the file, you are
not done.

Do the verification sweep **once, after the artifact is grown**. Verifying mid-growth is how a run
spends its budget on screenshots and ships thin.

## D. Polish checklist for interactive artifacts

These are the things that separate "generated" from "finished". Include each, or handle its
absence deliberately. Bullets marked *(...)* apply only to the artifact class named; the rest
apply to anything a human sees:

- **Crisp rendering**: size the canvas backing store by `devicePixelRatio` (clamped to ~3) and
  `scale()` the context, or it will be blurry on any modern display.
- **Touch**: `touch-action: manipulation`, no 300ms delay; pointer events not just mouse.
- **Viewport**: `100dvh` not `100vh` (mobile browser chrome), `aspect-ratio` to avoid reflow, and
  a `maximum-scale=1` decision you made on purpose.
- **First visit**: `localStorage`/`sessionStorage` behind try/catch — it throws in private mode.
- **Audio**: never construct an AudioContext before a user gesture; expose a mute control.
- **Accessibility**: `aria-label` on the interactive surface, visible focus, keyboard parity with
  pointer, and honor `prefers-reduced-motion`.
- **Feedback**: every input produces a perceptible response — press state, transition, sound, or
  motion. Silent input reads as broken.
- **Resilience**: a runtime error degrades to a readable message, never a black rectangle.
- **Copy**: instructions visible without digging; consistent type scale and spacing.
- **Progression** *(artifacts that run indefinitely)*: a loop the user can repeat forever without
  change is unfinished. Difficulty or intensity must respond to score or time on some axis, with a
  floor so it stays survivable.
- **Persisted high score** *(scored-loop artifacts only)*: compare against the value read at the
  *start* of the run, never the one you already mutated. Both common failure modes were shipped in
  testing: storing `best = score` on death then declaring `score >= best` claims a new record on
  every tie, and a fresh session where stored best is 0 claims one on the first point. Keep the
  pre-run value separate.
- **Death / failure state freezes the world it ended in** *(running-world artifacts only)*:
  scrolling ground or drifting clouds behind a dead player reads as a bug. Stop the world, keep the
  ambient layers if you keep them deliberately.

## E. Anti-cheat

Do not delete a failing state's variant to make the sweep pass. Do not capture only the state
that looks good. A screenshot of the idle screen is not proof the game works.
