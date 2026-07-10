# iPhone Client

The full SwiftUI capture app is not implemented yet. It arrives in its own
milestone (see IMPLEMENTATION_PLAN.md).

## Milestone 1.5 — capture spike (no app build required)

Goal: get real `CapturedRoom` JSON files into [samples/rooms/](../samples/)
so the measurement engine can be developed against real data.

### Steps

1. On the Mac, download Apple's RoomPlan sample project
   **"Create a 3D model of an interior room"** from the Apple Developer
   documentation for RoomPlan.
2. Open it in Xcode, set your development team, and run it on the iPhone
   (LiDAR-capable device required; Simulator will not work).
3. Scan a room following the on-screen guidance, tap **Done**, then **Export**.
   Recent versions of the sample export `Room.json` (the encoded
   `CapturedRoom`) alongside the USDZ model.
4. AirDrop the exported files to the Mac and copy the JSON into
   `samples/rooms/` using the naming convention in the samples README.

### If the sample version only exports USDZ

Add a JSON export next to the existing USDZ export in
`RoomCaptureViewController` (the sample keeps the final scan in a
`finalResults: CapturedRoom?` property):

```swift
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // deterministic diffs
let jsonData = try encoder.encode(finalResults)
let jsonURL = destinationFolderURL.appending(path: "Room.json")
try jsonData.write(to: jsonURL)
// then include jsonURL in the UIActivityViewController items
```

### Design rule for the future app

The phone sends Apple's `CapturedRoom` JSON **verbatim** — it never
transforms, summarizes, or converts scan data. All interpretation happens
in the backend, which keeps the phone thin and lets us re-run improved
measurement logic on old visits.
