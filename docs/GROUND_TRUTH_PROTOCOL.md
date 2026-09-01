# GROUND_TRUTH_PROTOCOL — measuring whether Build Pilot is right

Until this exists, no accuracy claim in this project is falsifiable: not the
engine's, not Decision 26's, not Decision 34's. `samples/` has never held a
single measured room. This protocol fixes that.

You have two advantages no competitor has: a laser measure, and you price
these rooms professionally every day. So we capture **two** kinds of truth —
what the room *is*, and what the job *should cost*. The second is worth more
than the first, and only you can produce it.

## Per room, on site (~3 minutes)

Do the scan **first**, before measuring — otherwise you will unconsciously
scan better than you normally would, and the data lies.

### 1. Scan (pick one pattern per room, rotate across rooms)

| Pattern | What to do | What it proves |
|---|---|---|
| **A — natural** | Scan the way you would if nobody were watching. Do not correct yourself. | The real-world baseline. This is the one that matters. |
| **B — deliberate** | Walk the full loop, every wall, corners last, until it closes. | The ceiling of what the sensor can do. |
| **C — obstructed** | Natural scan in the most furniture-heavy room of the day. Move nothing. | Where occlusion breaks it. |

Rotate so you end up with a spread of all three. Note the visit ID the app
gives you — that is what pairs the scan to this record.

### 2. Laser the room

- **Each wall**, corner to corner, at roughly waist height.
- **Ceiling height at two opposite corners.** If they differ by more than
  2 cm, record both — that tells us the flat-ceiling assumption is wrong in
  this room, which the engine currently cannot know.
- **Each door and window**, width × height.
- **Each built-in** that touches a wall: width × height, and which wall.

### 3. Conditions (ten seconds, from the list)

Flooring, mirrors or large glass, dark or gloss walls, room brightness,
furniture density. These map to the documented LiDAR failure modes and let
us explain a bad scan instead of just recording one.

### 4. Your estimate — the part nobody else can do

Before you see what the app produced, write down what **you** would quote:
paintable area, prep hours, protection hours, total hours, materials, and
the price you would actually put in front of the customer.

This is the only way we can ever test the estimator rather than just the
geometry. Your number is the target. If the app disagrees with you, the app
is wrong until proven otherwise.

## Recording it

One JSON file per room in `backend/tests/fixtures/ground_truth/`, named for
the visit ID, alongside the scan in `real_scans/`. See `EXAMPLE-room.json`
for the shape. Metric throughout, in metres and EUR (Decision 9).

Anything you cannot measure, leave out — a missing field is honest, a
guessed one poisons the whole corpus.

## What good looks like

Six to eight rooms makes the harness meaningful. Twenty makes it
authoritative, and gets us to a published tolerance — something magicplan
declines to state, telling users to buy a laser measurer instead. You have
the laser and you have the rooms.

## When a scan goes wrong

Keep it. A failed scan paired with correct laser measurements is the most
valuable record in the set — it is the only thing that shows us the size of
the error rather than the fact of it.
