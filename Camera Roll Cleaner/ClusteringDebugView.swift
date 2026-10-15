//
//  ClusteringDebugView.swift
//  Camera Roll Cleaner
//
//  TEMPORARY screen for checking the clustering logic actually works
//  before any chat UI or real "review your duplicates" flow is built on
//  top of it. Not meant to be a finished/polished screen — same
//  "scaffolding, not final UI" status PhotoGridView had for its own
//  milestone (see PROJECT_BRIEF.md).
//

import Photos
import SwiftUI

struct ClusteringDebugView: View {
    @StateObject private var clusterer = PhotoClusterer()

    var body: some View {
        List {
            Section {
                Button {
                    Task { await clusterer.run(in: PhotoClusterEngine.debugRange) }
                } label: {
                    if clusterer.isRunning {
                        HStack {
                            ProgressView()
                            Text("Scanning Sep 26 – Oct 4, 2025…")
                        }
                    } else {
                        Text("Run Clustering")
                    }
                }
                .disabled(clusterer.isRunning)
            }

            if let result = clusterer.result {
                Section("Summary") {
                    LabeledContent("Photos scanned", value: "\(result.totalScanned)")
                    LabeledContent("Duplicate clusters", value: "\(result.duplicateClusters.count)")
                    LabeledContent("Singles excluded", value: "\(result.singles.count)")
                }

                Section("Duplicate Clusters") {
                    ForEach(Array(result.duplicateClusters.enumerated()), id: \.element.id) { index, cluster in
                        NavigationLink {
                            AssetGridView(assets: cluster.members.map { $0.asset })
                                .navigationTitle("Cluster \(index + 1) — \(cluster.members.count) photos")
                        } label: {
                            clusterRow(index: index, cluster: cluster)
                        }
                    }
                }

                if !result.singles.isEmpty {
                    Section {
                        NavigationLink {
                            StragglerFolderView(stragglerAssets: result.singles.map { $0.asset })
                        } label: {
                            Text("View Unmatched Photos (\(result.singles.count))")
                        }
                    } footer: {
                        Text("These photos had no matching duplicates and are not part of any cluster shown above.")
                    }
                }

                if !result.nearMisses.isEmpty {
                    Section("Near Misses (\(result.nearMisses.count)) — close in time, landed in different clusters") {
                        ForEach(result.nearMisses) { pair in
                            nearMissRow(pair)
                        }
                    }
                }

                if !result.failedAssets.isEmpty {
                    Section("Failed to Process (\(result.failedAssets.count))") {
                        ForEach(result.failedAssets) { failed in
                            HStack(spacing: 10) {
                                PhotoThumbnailView(asset: failed.asset, targetSize: CGSize(width: 50, height: 50))
                                    .frame(width: 50, height: 50)
                                    .clipped()
                                    .cornerRadius(6)
                                Text(failed.reason)
                                    .font(.caption2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Clustering Debug")
    }

    private func nearMissRow(_ pair: NearMissPair) -> some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 4) {
                PhotoThumbnailView(asset: pair.a.asset, targetSize: CGSize(width: 60, height: 60))
                    .frame(width: 60, height: 60)
                    .clipped()
                    .cornerRadius(6)
                PhotoThumbnailView(asset: pair.b.asset, targetSize: CGSize(width: 60, height: 60))
                    .frame(width: 60, height: 60)
                    .clipped()
                    .cornerRadius(6)
            }
            VStack(alignment: .leading, spacing: 3) {
                gateLine(
                    "Similarity",
                    passed: pair.passedSimilarity,
                    detail: pair.featurePrintDistance.map { String(format: "%.3f", $0) } ?? "error"
                )
                gateLine("Time gap", passed: pair.passedTime, detail: "\(Int(pair.timeGapSeconds))s")
                gateLine(
                    "Location",
                    passed: pair.passedLocation,
                    detail: pair.locationDistanceMeters.map { String(format: "%.0fm apart", $0) } ?? "no GPS data"
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func gateLine(_ name: String, passed: Bool, detail: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
                .font(.caption2)
            Text("\(name): \(detail)")
                .font(.caption2)
        }
    }

    private func clusterRow(index: Int, cluster: PhotoCluster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cluster \(index + 1) — \(cluster.members.count) photos")
                .font(.headline)
            HStack(spacing: 12) {
                PhotoThumbnailView(asset: cluster.representative.asset, targetSize: CGSize(width: 70, height: 70))
                    .frame(width: 70, height: 70)
                    .clipped()
                    .cornerRadius(6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Representative")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Sharpness score: \(String(format: "%.1f", cluster.representative.sharpness))")
                        .font(.caption2)
                    if !cluster.representative.faceQualities.isEmpty {
                        Text("Face quality: \(cluster.representative.faceQualities.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
                            .font(.caption2)
                    }
                    if let eyes = cluster.representative.eyesOpenScore {
                        Text("Eyes-open score: \(String(format: "%.2f", eyes))")
                            .font(.caption2)
                    } else {
                        Text("No face detected")
                            .font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ClusteringDebugView()
    }
}
