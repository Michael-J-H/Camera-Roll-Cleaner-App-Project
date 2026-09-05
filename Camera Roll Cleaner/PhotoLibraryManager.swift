//
//  PhotoLibraryManager.swift
//  Camera Roll Cleaner
//
//  Handles Photos permission and fetching the list of photos in the library.
//

import Photos
import SwiftUI

@MainActor
final class PhotoLibraryManager: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var assets: [PHAsset] = []

    init() {
        // .readWrite is the access level to check/request here even though this app
        // only reads for now — iOS doesn't offer a separate "read only" level. The
        // other option, .addOnly, is for apps that just save new photos and can't
        // browse the existing library at all, which isn't useful for a photo grid.
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status == .authorized || status == .limited {
                    self?.loadAssets()
                }
            }
        }
    }

    func loadAssetsIfAuthorized() {
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            loadAssets()
        }
    }

    private func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            fetched.append(asset)
        }
        assets = fetched
    }
}
