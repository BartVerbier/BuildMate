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

Connection is zero-config: run `python -m buildpilot` on the Mac (see
[backend/README.md](../backend/README.md)) and the app finds it via Bonjour —
on first Start Visit, or from Settings (gear), where discovered Macs are
listed. Manual address entry exists as a fallback under Settings → Advanced.

## Screens (dark appearance, green accent)

1. **Visits** — recent visits with their quotes, one primary action:
   Start New Visit. Settings (business identity for the quote + Mac
   discovery) behind the gear.
2. **Capture** — Apple's native RoomPlan experience full-bleed, with a live
   recording pill (timer + mic) and a Finish Visit button. Cancel asks
   before discarding.
3. **Processing** — a calm three-step checklist (room scan, audio, drafting
   on your Mac). The screen stays awake so a phone on the kitchen table
   never kills the upload.
4. **Read-back** — the sales moment before the price: "Today we've
   discussed" lists the agreed scope in the customer's own words and asks
   "anything else before I prepare your quote?" (Decision 20). Only then:
5. **Draft Estimate** — the price as hero, then breakdown, room measurements,
   scope/exclusions/prep/notes, and a customer-safe "How this was calculated"
   (quantities and coverage — internal pricing never appears on the phone).
   **Share Quote** renders a print-styled PDF with the painter's business
   identity and opens the native share sheet (Mail, Messages, WhatsApp,
   AirDrop, Print, Save to Files).

## Project layout

- `project.yml` — XcodeGen spec (the `.xcodeproj` is generated, not committed)
- `Sources/VisitController.swift` — visit state machine
- `Sources/VisitHistory.swift` — on-device recent-visit store
- `Sources/RoomCaptureController.swift` — RoomPlan session + CapturedRoom JSON export
- `Sources/AudioRecorder.swift` — AVFoundation m4a recording
- `Sources/BackendClient.swift` — BackendClient protocol + HTTP implementation + BackendLocator (the one-line cloud switch)
- `Sources/ContentView.swift` — root + visit flow presentation
- `Sources/VisitsHomeView.swift`, `CaptureVisitView.swift`,
  `ProcessingView.swift`, `EstimateView.swift` — the four screens
- `Sources/QuotePDF.swift` — print-styled PDF quote for the share sheet
- `Sources/Format.swift` — display formatting

## Design rules

- The phone sends Apple's `CapturedRoom` JSON **verbatim** — no
  transformation, no unit conversion (docs/DECISIONS.md, Decisions 9 & 10).
- The phone stays thin: all interpretation happens in the backend.

## Capture spike (still useful)

To collect standalone room-scan fixtures for `samples/rooms/` without the
backend running, Apple's RoomPlan sample app also works — scan, export, and
AirDrop the JSON. See `samples/README.md` for the checklist.
