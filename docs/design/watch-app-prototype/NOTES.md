# Lift Log for Apple Watch — concept notes (PROTOTYPE)

> Design record: Option C — Rings shipped as `LiftLogWatch` (see
> [Watch architecture](../../ARCHITECTURE.md#watch-remote-foundation)). This folder
> preserves the original exploration and verdict.

**Question being answered:** How should starting a workout, completing a set,
resting, and finishing feel on the wrist — one-handed, mid-set, at a glance?

**Prototype:** `index.html` in this folder. Open it in a browser
(`python3 -m http.server` in this folder, or double-click the file).
Three directions switchable via the floating bar, ← → keys, or `?variant=A|B|C`.
The top watch is clickable; the board below shows every screen.

## Verdict

- Direction picked: **C — Rings** (2026-10-21, owner decision).
- Bits stolen from other directions: none for v1; A's one-tap complete stays
  as the full-width button under the ring.
- Open decisions resolved for v1: (1) Watch is a remote for the iPhone's
  active workout via WatchConnectivity; actions queue offline by set ID.
  (2) No HKWorkoutSession in v1 — no heart-rate row. (3) Crown adjusts reps;
  weight adjustable by tapping the weight value. (4) Rest follows the
  existing phone rule (fires on a completion when sets remain) — superset
  round rule revisited only with a core change. (5) +30s extends the current
  timer's deadline only. (6) In-app haptic on Watch; phone notification
  remains the background alert (device check for mirror duplication).
  (7) Timers render from stored dates.

## Scope proposed for v1 (review this, not just the visuals)

In: start from template / resume active workout, complete a set at target,
adjust reps (and maybe weight) with the Crown, rest countdown with +30s/Skip,
rest-complete haptic notification, next-exercise advance incl. supersets,
finish (save completed only) and discard with confirmation.

Out (stays on iPhone in v1): creating/editing templates, adding/swapping/
reordering exercises, history, assistant, Health dashboard.

## How the concept reuses today's rules

- One active workout at a time; starting is blocked while one is active
  (Resume shown instead) — `WorkoutStore.startWorkout` guard.
- Rest is a stored deadline (`WorkoutRestTimer.endsAt`), not a tick count,
  so wrist-down/suspension cannot drift it. Default 2:00, `0` = Off.
- No rest timer after the final set or when no incomplete set remains —
  `WorkoutRestTimer.updated`.
- Editing a set's values affects that set and later incomplete sets only;
  completed sets are immutable — `WorkoutExercise.updateSetValues`.
- Finish saves completed sets only and requires at least one completed set;
  discard deletes logged sets after confirmation — `ActiveWorkoutView`.
- Rest-complete copy ("Rest complete / Time to start your next set") mirrors
  the existing iPhone notification in `RestTimerAlerts`, extended with the
  next set's prescription (already computed for `WorkoutActivitySnapshot`).
- Units always travel with the workout (`WorkoutSession.unit`); the Watch
  never re-converts history.

## The three directions

| | A — Focus | B — List | C — Rings |
|---|---|---|---|
| Idea | One job per screen, giant Complete target | iPhone list shrunk, crown scroll | Fitness-style cards, progress ring hero |
| Complete a set | 1 tap, full-width | Tap the row's ✓ | 1 tap below the ring |
| See whole workout | Swipe pages | Native — it's a list | Summary card swipe |
| Rest | Full-screen digits + bar | Pinned card atop list | Full-screen ring |
| Risk | Context hidden | Mis-taps, slow mid-set | Ring eats text size |

## Flow (all directions)

Start/Resume → Next set → (Crown: adjust) → Complete → Rest countdown
(+30s/Skip) → Rest-complete haptic → Next set … → Exercise done → Up next →
… → Controls → Finish? → Save → Saved. Discard lives on Controls only.

## Open decisions for the owner

1. **Remote vs standalone.** (a) Watch controls the iPhone's active workout
   via WatchConnectivity, queuing taps offline by set ID (assumed here); or
   (b) Watch can run a full workout with the phone absent and merge later.
   (b) needs conflict rules if both devices edit the same set.
2. **HKWorkoutSession?** Running one keeps the app frontmost/always-on and
   enables heart-rate + Fitness credit, but adds HealthKit workout
   permissions and session lifecycle. Direction C shows HR only under this.
3. **Weight editing on wrist?** Reps via Crown is cheap; weight in 2.5 lb /
   1 kg steps is doable but slower. Alternative: reps only, fix weight later
   on iPhone (targets preserved, so nothing is lost).
4. **Superset rest rule.** Concept assumes rest starts after the round
   (A1+A2), not between partners. Today rest fires on any completion.
5. **+30s semantics.** Extend the current timer's deadline (assumed) vs
   change `restSeconds` for the rest of the workout.
6. **Who alerts?** Proposed: Watch (haptic) when worn/unlocked, iPhone
   notification otherwise — never duplicate. Needs coordination with the
   existing `RestTimerAlerts` dedupe by timer ID.
7. **Always-on / wrist-down.** Dimmed state should still show rest digits and
   next set (dates render natively, like the Live Activity payload).

## watchOS constraints baked into the mock

- 41/45 mm safe area, black background, no keyboard; Crown + tap + swipe only.
- Minimum glance text kept large; meaning never by colour alone (✓, labels).
- VoiceOver order = title → prescription → primary action on every screen.
- All timers derive from `endsAt`/`startedAt` dates — no per-second wakeups.
