import SwiftUI

/// The scan-closure review (Decision 34, guided capture v1): the wall loop
/// didn't close, so before anything is uploaded the painter sees exactly
/// which wall ends are hanging open and chooses — walk the room again, or
/// proceed knowing the estimate will be flagged and not quotable until the
/// measurements are verified. Never a trap, never silent.
struct ScanReviewView: View {
    @ObservedObject var visit: VisitController
    let status: WallLoopStatus

    private var openEnds: [OpenWallEnd] {
        if case .open(let ends, _) = status { return ends }
        return []
    }

    private var wallCount: Int {
        if case .open(_, let count) = status { return count }
        return 0
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: BPSpacing.l) {
                    header
                    sketchCard
                    gapList
                    consequence
                }
                .padding(20)
            }
            actionBar
        }
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The room isn't complete", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text("The scan found \(wallCount) wall\(wallCount == 1 ? "" : "s"), but they don't close the room — usually furniture blocked a wall, or a section was missed on the walk.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// The room as scanned, open ends ringed in red — the painter sees
    /// where the holes are instead of decoding wall numbers.
    private var sketchCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoomSketch(footprints: visit.scanReviewFootprints, openEnds: openEnds)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Your scan from above — the red rings are where the walls don't meet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var gapList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open ends")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            ForEach(Array(openEnds.enumerated()), id: \.offset) { _, gap in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wall \(gap.wallId.dropFirst()) has an open end")
                            .font(.body.weight(.medium))
                        if let gapM = gap.gapM, let nearest = gap.nearestWallId {
                            Text("\(Format.metres(gapM)) of wall missing to wall \(nearest.dropFirst())")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var consequence: some View {
        Text("You can use this scan anyway — the draft will show the price of what was scanned, marked \u{201C}not ready to quote\u{201D} until you verify the measurements on site.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                visit.scanTheGaps()
            } label: {
                Label("Scan the Missing Walls", systemImage: "arrow.clockwise")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)

            Button {
                visit.useScanAnyway()
            } label: {
                Text("Use Anyway — mark for on-site check")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
