//
//  PhotoGridView.swift
//  Camera Roll Cleaner
//
//  Scrolling grid of camera roll thumbnails, plus the permission states
//  around it (not asked yet / denied / granted).
//

import Photos
import SwiftUI
import UIKit

struct PhotoGridView: View {
    @StateObject private var libraryManager = PhotoLibraryManager()

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Camera Roll")
        }
        .onAppear {
            libraryManager.loadAssetsIfAuthorized()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch libraryManager.authorizationStatus {
        case .notDetermined:
            requestAccessView
        case .limited where libraryManager.assets.isEmpty:
            // Choosing "Limit Access" and then picking zero photos in the
            // follow-up picker lands here — access was granted, but to
            // nothing. Without this case it looks identical to a bug: a
            // blank grid with no error and no explanation.
            noPhotosSelectedView
        case .authorized, .limited:
            gridView
        case .denied, .restricted:
            deniedView
        @unknown default:
            deniedView
        }
    }

    private var requestAccessView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("This app needs access to your photos to show them here.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Allow Access") {
                libraryManager.requestAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Photo access was denied. Enable it in Settings to see your camera roll here.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var noPhotosSelectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("You've limited this app to specific photos, but none are currently selected. Choose photos in Settings to see them here.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(libraryManager.assets, id: \.localIdentifier) { asset in
                    PhotoThumbnailView(asset: asset, targetSize: CGSize(width: 150, height: 150))
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                }
            }
        }
    }
}

#Preview {
    PhotoGridView()
}
