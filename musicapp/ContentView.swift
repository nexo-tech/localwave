import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct AudioFile: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let artist: String
    let artwork: UIImage?
}

struct ContentView: View {
    @State private var folderURL: URL?
    @State private var isFileImporterPresented = false
    @State private var audioFiles: [AudioFile] = []
    @State private var isLoading = false

    var body: some View {
        VStack {
            Text("Hello, Doggyman!")

            if let folderURL {
                Text("Selected Folder: \(folderURL.path)")
                    .font(.caption)

                Button("Load Audio Files") {
                    Task {
                        print("[UI] Load button pressed — starting BFS + metadata fetch")
                        await loadAudioFilesBFS(from: folderURL)
                    }
                }
                .padding()
            } else {
                Text("No folder selected")
                    .font(.caption)
            }

            Button("Select Folder") {
                isFileImporterPresented = true
                print("[UI] Select Folder tapped")
            }
            .padding()

            if isLoading {
                ProgressView("Loading...")
            } else if !audioFiles.isEmpty {
                List(audioFiles) { file in
                    HStack {
                        if let artwork = file.artwork {
                            Image(uiImage: artwork)
                                .resizable()
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                        } else {
                            Image(systemName: "music.note")
                                .resizable()
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading) {
                            Text(file.title)
                                .font(.headline)
                            Text(file.artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            print("[FileImporter] result: \(result)")
            switch result {
            case .success(let urls):
                if let selectedFolder = urls.first {
                    folderURL = selectedFolder
                    audioFiles = []
                    print("[FileImporter] Folder chosen: \(selectedFolder.path)")
                }
            case .failure(let error):
                print("[FileImporter] Error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - BFS + Concurrency
extension ContentView {
    func loadAudioFilesBFS(from folderURL: URL) async {
        print("[BFS] Starting BFS from: \(folderURL.path)")
        isLoading = true
        var audioURLs: [URL] = []
        let fm = FileManager.default
        var visited: Set<URL> = []
        var queue: [URL] = [folderURL]

        guard folderURL.startAccessingSecurityScopedResource() else {
            print("[BFS] Failed to access security-scoped resource.")
            isLoading = false
            return
        }
        defer {
            print("[BFS] Stopping access to security-scoped resource.")
            folderURL.stopAccessingSecurityScopedResource()
        }

        while !queue.isEmpty {
            let current = queue.removeFirst().resolvingSymlinksInPath()
            print("[BFS] Dequeued folder: \(current.path)")
            guard !visited.contains(current) else {
                print("[BFS] Already visited \(current.path), skipping...")
                continue
            }
            visited.insert(current)

            do {
                let items = try fm.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .ubiquitousItemDownloadingStatusKey,
                    ],
                    options: [.skipsHiddenFiles]
                )
                print("[BFS] Found \(items.count) items in \(current.lastPathComponent)")

                for item in items {
                    let rv = try item.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .ubiquitousItemDownloadingStatusKey,
                    ])

                    if rv.isSymbolicLink == true {
                        print("[BFS] Skipping symbolic link: \(item.path)")
                        continue
                    }

                    if rv.isDirectory == true {
                        if let status = rv.ubiquitousItemDownloadingStatus, status == .notDownloaded
                        {
                            do {
                                print(
                                    "[BFS] Subfolder not downloaded, requesting download: \(item.lastPathComponent)"
                                )
                                try fm.startDownloadingUbiquitousItem(at: item)
                                // We'll skip adding to BFS queue until it’s downloaded
                            } catch {
                                print("[BFS] Error requesting iCloud subfolder download: \(error)")
                            }
                            continue
                        }
                        print("[BFS] Subfolder found, adding to queue: \(item.lastPathComponent)")
                        queue.append(item)
                    } else {
                        let ext = item.pathExtension.lowercased()
                        if ["mp3", "m4a"].contains(ext) {
                            if let status = rv.ubiquitousItemDownloadingStatus,
                                status == .notDownloaded
                            {
                                print(
                                    "[BFS] File not downloaded (\(item.lastPathComponent)), requesting download..."
                                )
                                do {
                                    try fm.startDownloadingUbiquitousItem(at: item)
                                } catch {
                                    print("[BFS] Error requesting iCloud file download: \(error)")
                                    continue
                                }
                                print("[BFS] Waiting for \(item.lastPathComponent) to download...")
                                await waitForDownloadIfNeeded(item)
                                print("[BFS] \(item.lastPathComponent) finished downloading!")
                            }
                            print(
                                "[BFS] Audio file found, adding to list: \(item.lastPathComponent)")
                            audioURLs.append(item)
                        }
                    }
                }
            } catch {
                print(
                    "[BFS] Error reading directory \(current.path): \(error.localizedDescription)")
            }
        }

        print("[BFS] BFS complete. Total audio files found: \(audioURLs.count)")
        // 2) Parallel metadata reading
        print("[BFS] Starting parallel metadata fetch...")
        let found = await fetchMetadataConcurrently(from: audioURLs)
        print("[BFS] Finished parallel metadata fetch, found: \(found.count) audio files")

        DispatchQueue.main.async {
            self.audioFiles = found
            self.isLoading = false
        }
    }

    private func waitForDownloadIfNeeded(_ fileURL: URL) async {
        let fm = FileManager.default
        print("[Download Wait] Checking status for \(fileURL.lastPathComponent)")
        while true {
            do {
                let rv = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if rv.ubiquitousItemDownloadingStatus == .current {
                    print("[Download Wait] \(fileURL.lastPathComponent) is fully downloaded.")
                    return
                }
            } catch {
                print("[Download Wait] Error checking \(fileURL.lastPathComponent): \(error)")
            }
            do {
                try fm.startDownloadingUbiquitousItem(at: fileURL)
            } catch {
                print(
                    "[Download Wait] Error re-requesting download for \(fileURL.lastPathComponent): \(error)"
                )
            }
            print("[Download Wait] \(fileURL.lastPathComponent) still not downloaded; waiting...")
            try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3s
        }
    }

    private func fetchMetadataConcurrently(from urls: [URL]) async -> [AudioFile] {
        await withTaskGroup(of: AudioFile?.self) { group in
            for url in urls {
                group.addTask {
                    print("[Metadata] Fetching metadata for \(url.lastPathComponent)")
                    return getAudioMetadata(for: url)
                }
            }

            var results: [AudioFile] = []
            for await result in group {
                if let audioFile = result {
                    results.append(audioFile)
                }
            }
            return results
        }
    }

    private func getAudioMetadata(for fileURL: URL) -> AudioFile? {
        print("[Metadata] Reading asset for \(fileURL.lastPathComponent)")
        let asset = AVAsset(url: fileURL)
        let common = asset.commonMetadata
        let title =
            common.first(where: { $0.commonKey?.rawValue == "title" })?.stringValue
            ?? fileURL.deletingPathExtension().lastPathComponent
        let artist =
            common.first(where: { $0.commonKey?.rawValue == "artist" })?.stringValue
            ?? "Unknown Artist"
        let artworkData =
            common.first(where: { $0.commonKey?.rawValue == "artwork" })?.value as? Data
        let artwork = artworkData.flatMap { UIImage(data: $0) }

        print("[Metadata] -> Title: \(title), Artist: \(artist)")
        return AudioFile(url: fileURL, title: title, artist: artist, artwork: artwork)
    }
}

#Preview {
    ContentView()
}
