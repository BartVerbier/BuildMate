# Samples

Real capture data used as fixtures for the measurement engine (Milestone 2).

## What belongs here

- `rooms/` — RoomPlan `CapturedRoom` JSON exports, verbatim from the device.
- `sessions/` — example `session.json` documents matching the current schema.

## Room scan fixtures — capture checklist

Milestone 1.5 requires at least **3 real room scans**, captured with the
founder's iPhone (see [iphone/README.md](../iphone/README.md) for how).

Aim for variety — the measurement engine will be tuned against these:

1. A plain rectangular room (baseline).
2. A room with several doors and windows (net-area subtraction).
3. At least one awkward room: bay window, sloped ceiling, open doorway,
   or built-in wardrobes.

## Naming convention

```text
rooms/<short-description>-<yyyymmdd>.json
e.g. rooms/bedroom-plain-20260712.json
     rooms/living-room-bay-window-20260712.json
```

## Rules

- Files are committed **verbatim** as exported by the device. Never edit,
  reformat, or "fix" a captured file — fixtures must stay honest.
- All RoomPlan data is in metres. It stays in metres (see docs/DECISIONS.md).

## Status

- [ ] Awaiting first real scans (founder task — requires physical iPhone with LiDAR).
