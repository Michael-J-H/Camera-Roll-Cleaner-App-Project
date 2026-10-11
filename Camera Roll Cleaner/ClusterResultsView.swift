//
//  ClusterResultsView.swift
//  Camera Roll Cleaner
//
//  The chat's "here's what I found" screen — the user-facing counterpart to
//  ClusteringDebugView, scoped to only what v1's chat flow is meant to show.
//  Per PROJECT_BRIEF.md's decided UX, singles (no-duplicate photos) are
//  excluded entirely from the review/deletion flow, not just hidden by
//  default — so unlike the debug screen, there's no "Unmatched Photos" link
//  here, and no near-miss/failed-asset diagnostics (those are tuning tools
//  for the debug screen, not something a real user needs to see).
//

import SwiftUI

struct ClusterResultsView: View {
    let result: ClusteringResult
    let dateRange: DateInterval

    var body: some View {
        List {
            Section {
                LabeledContent("Photos scanned", value: "\(result.totalScanned)")
                LabeledContent("Duplicate sets", value: "\(result.duplicateClusters.count)")
            }

            Section("Duplicate Sets") {
                ForEach(Array(result.duplicateClusters.enumerated()), id: \.element.id) { index, cluster in
                    NavigationLink {
                        AssetGridView(assets: cluster.members.map { $0.asset })
                            .navigationTitle("Set \(index + 1) — \(cluster.members.count) photos")
                    } label: {
                        clusterRow(index: index, cluster: cluster)
                    }
                }
            }
        }
        .navigationTitle("Review Duplicates")
    }

    private func clusterRow(index: Int, cluster: PhotoCluster) -> some View {
        HStack(spacing: 12) {
            PhotoThumbnailView(asset: cluster.representative.asset, targetSize: CGSize(width: 60, height: 60))
                .frame(width: 60, height: 60)
                .clipped()
                .cornerRadius(6)
            Text("Set \(index + 1) — \(cluster.members.count) photos")
        }
        .padding(.vertical, 2)
    }
}
