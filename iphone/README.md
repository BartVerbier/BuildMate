# iPhone Client

The Build Pilot capture app: **Start Visit → scan + record → Finish Visit →
review draft estimate.**

## What it does

- `Start Visit` starts a RoomPlan capture session and audio recording
  simultaneously. (RoomPlan owns LiDAR and the camera — there is no separate
  "LiDAR capture"; that's Apple's intended architecture.)
- `Finish Visit` stops both, lets RoomPlan run its final processing pass,
  encodes the `CapturedRoom` verbatim as JSON, and uploads
  `room.json + visit.m4a` to the Mac backend as one multipart request.
- The completed session comes back with the draft estimate, shown on the
  review screen with measurements, scope, and the full calculation trail.

## Build and run (requires Xcode + a LiDAR iPhone)

```bash
cd iphone/BuildPilot
xcodegen generate            # brew install xcodegen (already done on this Mac)
open BuildPilot.xcodeproj
```

In Xcode: select your development team under Signing & Capabilities, pick
your iPhone as the destination, and run. The Simulator will not work —
RoomPlan requires LiDAR hardware.

In the app, set the backend URL on the start screen to your Mac's LAN
address, e.g. `http://192.168.1.23:8787` (find it via System Settings →
Wi-Fi → Details, and make sure the backend is running — see
[backend/README.md](../backend/README.md)).

## Project layout

- `project.yml` — XcodeGen spec (the `.xcodeproj` is generated, not committed)
- `Sources/VisitController.swift` — visit state machine
- `Sources/RoomCaptureController.swift` — RoomPlan session + CapturedRoom JSON export
- `Sources/AudioRecorder.swift` — AVFoundation m4a recording
- `Sources/SessionUploader.swift` — multipart upload to the Mac
- `Sources/ContentView.swift`, `EstimateView.swift` — the three-screen UI

## Design rules

- The phone sends Apple's `CapturedRoom` JSON **verbatim** — no
  transformation, no unit conversion (docs/DECISIONS.md, Decisions 9 & 10).
- The phone stays thin: all interpretation happens in the backend.

## Capture spike (still useful)

To collect standalone room-scan fixtures for `samples/rooms/` without the
backend running, Apple's RoomPlan sample app also works — scan, export, and
AirDrop the JSON. See `samples/README.md` for the checklist.
