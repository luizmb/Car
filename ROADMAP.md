# SpeedJarvis — roadmap

An audio-first riding assistant for a 2008 Honda VT400 with no working instruments: unreliable
odometer and speedometer, no fuel gauge, no warning lights, and a reserve tank whose use damages the
carburettor. Everything here exists because the bike cannot tell the rider something it should.

**Current priority: stability.** No new capability until a week of rides produces clean, complete
records. Everything in "Later" is deliberately parked, not forgotten.

---

## Standing constraints

These are not negotiable and shape every item below.

- **No Russia or China.** No service operated in or by either jurisdiction touches this data — not as
  a mirror, a CDN, an SDK, or a temporary workaround, and not even when it is the only thing that
  works. When every acceptable provider is down, the feature degrades honestly.
- **Purity.** No ambient state — `Date()`, `UUID()`, `Locale.current`, `Calendar.current` and friends
  are injected. No `throws`, no bare `await` inside domain code; effects live in the Store boundary.
- **No infrastructure in the domain.** No database annotation, protocol or attribute reaches
  `AppDomain`. Persistence dies at the `World` boundary.
- **An honest gap beats a wrong answer.** A missing speed limit is safe; a confidently wrong one is
  not.

---

## Now — stability

The app is ridden daily and the failures below all cost a real ride's data.

### 1. Journey survives an app kill

A force-quit mid-ride leaves a `journey-start` with no `journey-end`, and relaunching opens a second
journey. Every hand-pulled log so far has this hole, because pulling the log *requires* force-quitting
(`devicectl` truncates a file being actively written).

The journey's open state has to outlive the process. Smallest thing that works: persist the start
marker, and on launch either resume it or close it from the last known fix.

### 2. The stale-timestamp window

Journey end is a conjunction of ignition signals going quiet. If Indimate dies mid-ride — flat cell,
BLE drop — the journey closes at that instant rather than at the real end, and the rest of the ride
is unrecorded.

A ~60 s window before accepting a signal's silence as real fixes it, at the cost of ending every
journey a minute late. That trade is clearly worth it.

### 3. No-signal failsafe

If both CHIGEE and Indimate fail to connect, no journey opens and the entire ride vanishes silently.
CoreMotion's `automotive` state is the backstop: sustained vehicular motion with no open journey
should open one. It is not a *good* ignition signal, which is why it is a failsafe rather than a
third input to the disjunction.

### 4. Debug log

Daily rotation already exists — `ActionLog` rolls to `debug-YYYY-MM-DD.jsonl` on the first line
written after midnight UTC, and appends within a day so a relaunch does not erase the morning.

**Deliberately manual for now:** the rider deletes the day's file by hand. No automatic pruning, no
size cap, no in-app deletion — an automatic rule that eats a log the day something interesting
happens is worse than a large file. Revisit only if a single day's file becomes a problem to pull;
42 MB was already awkward.

### 5. Siri

No phrase has ever worked. Every request routed to HomeKit answering "none of your accessories can
respond to that", including after cold launches and with both "SpeedJarvis" and "Bike".

`CFBundleSpokenName` is now "Bike" on the theory that App Shortcut phrases must contain the app name
and the name has to be pronounceable. **This is untested.** Next step is purely diagnostic: does
Shortcuts → App Shortcuts list the app, and does tapping the shortcut there work? That separates
"the intents are broken" from "Siri will not route to them".

If Siri still refuses, the answer is a personal shortcut with a user-chosen phrase, not more phrase
tuning. Do not spend further effort guessing at Siri's matcher.

### 6. Undecided: the micro-journey rule

Journeys under ~5 minutes *or* under ~200 m were to be discarded as noise — moving the bike in the
garage, a false ignition trigger.

`or` deletes real rides: a five-minute trip to the shop is a genuine journey. `and` only discards
things that are both brief and stationary, which is the actual definition of noise. Distance-only is
the simplest rule that works.

**This needs a decision before it ships.** Recommendation: `and`.

---

## Next — making the data worth having

Once rides record cleanly, the records become the product.

### Monotonic trip counter

Distance since the last fill is currently derived by resetting a counter, which makes it impossible
to recompute history or correct a mistyped odometer reading. Store cumulative distance and take
differences. One source of truth, and every derived number becomes recomputable.

### A queryable store

JSONL is the right format for an append-only record and the wrong one for "show me every fill at
this station" or "plot consumption over the year". SQLite at the `World` boundary, with the domain
models untouched — no ORM annotations, no `@Model`, no protocol conformances reaching inward.

Explicitly rejected: SwiftData and CloudKit. The objection is not Apple-only-ness — this app is
Apple-only. It is that both demand their vocabulary inside the model layer.

Eventually a *compacter*: full fidelity for recent rides, summaries for old ones.

### Journey views

The reason for all of the above. A journey list, a map of the route, layers (speed, altitude, road
class, limit compliance), charts, and the fuelling history with price per litre by station.

### Average-speed zones

The announcement says a zone has begun but nothing tracks the rider's mean through it, which is the
only number that matters in one. Needs the running average and an announcement as the zone ends.

---

## Fuel

Working today: consumption maths, station identity resolved at the moment of recording (so a fill can
never be attributed later by clustering coordinates), spec-based range, and an announcement at every
journey start — because that is the moment the rider is otherwise completely in the dark.

The tank figures are an **assumption to be replaced by data**: 9 L main, 14 L total. There is no
manual; consensus online is 14 L with 3.6 L reserve, but the bike goes weak around 9 L from brim, so
usable-before-reserve is raised only by intervals containing no reserve switch. The first recorded
fill is excluded from statistics — the starting level was unknown.

As real intervals accumulate, replace the constants with measured values and say how confident the
estimate is.

---

## Road data

The on-device extract is now the primary source; Overpass is cache refresh and backup. Open:

- **Refreshing the extract.** It is a hand-copied snapshot today. OSM moves — new limits, new
  cameras. Needs at minimum a "this file is from *date*" and a way to replace it.
- **Cameras and stations from the file.** Both are already extracted and indexed, and both still go
  to the network. Serving them locally removes the last per-ride Overpass dependency.
- **Size.** England is 500 MB with service roads, 269 MB without. Service roads matter for road
  selection near driveways and car parks — dropping them re-opens a bug that was already fixed once.
  A regional cut (London → Cambridge, covering the actual riding area) is the better lever if size
  becomes a problem.
- **Self-hosted Overpass** would remove the rate limit entirely, at the cost of running a server.
  Only worth it if the extract approach proves insufficient.

---

## Battery

The plan, in order, and **blocked until a week of journey markers exists**:

1. Idle every sensor while parked — GPS, motion, BLE scanning, road lookup.
2. Keep exactly one cheap trigger alive. That trigger wakes a more reliable one; the reliable one
   opens the journey.
3. A ~30 s grace period so a brief signal loss does not thrash the whole chain.

The audio session is part of this — an active `.playback` session with `.duckOthers` dips every
other app's audio for as long as it is held. It is deliberately **not** released between journeys
yet, because gating audio while GPS, motion and the road lookup all still run continuously is one
piece of the plan out of order, and it adds a failure mode before the observation week meant to
inform the whole thing.

Interim: a manual "Recording…" toggle, so the rider can stop the drain by hand without waiting for
the automation.

---

## Hardware

Confirmed model, consistent across three journeys: **CHIGEE tracks the keys, Indimate tracks the
engine.** Indimate connects 19–35 s after CHIGEE (engine start); on key-off Indimate drops first,
CHIGEE follows 20–21 s later.

- **Indimate voltage.** The battery reading is not reported reliably. Needs a PacketLogger capture in
  the garage to find what the vendor app asks for. Not a today job.
- **Cardo control channel.** GATT mapped: service `CD007F83-…`, notify `CD007F82-…`, and a writable
  `CD007F81-…`. Ducking intercom audio during announcements is the plausible use. **Nothing is
  written until the protocol is understood** — unknown opcodes at a helmet intercom can land on
  firmware-update or factory-reset paths, and it is the device every announcement comes out of.
  Battery is a coarse ladder (100/25/5 observed), not a percentage.
- **CHIGEE footage.** The dashcam holds video. Pulling a clip around a hard-braking event or an
  incident is the interesting version of this.
- **Apple Watch.** Sceptical, and the scepticism is right. The screen is unreadable at speed with a
  helmet on and gloves make it untouchable. The only defensible use is **haptics** — a wrist tap for
  a camera ahead or a limit change, where audio would be lost under wind or music. Not worth an app.

---

## Navigation

Wanted, with routing preferences the mainstream apps do not offer: *no motorways*, *motorways as
much as possible*, and *no narrow lanes that are dangerous on two wheels*.

GraphHopper and Valhalla are both free and open-source with custom routing profiles, and both need
4–8 GB RAM to serve England — so either a self-hosted server or a substantial escalation of on-device
work. The map data is already downloaded and processed, which is the part that would otherwise be
hard.

Parked until the app is stable. It is the largest single item here.
