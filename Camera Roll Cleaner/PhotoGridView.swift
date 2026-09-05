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
