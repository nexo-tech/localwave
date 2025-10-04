//
//  TUISourceScanView.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import SwiftTUI
import LocalWaveDomain
import LocalWaveCore
import LocalWaveData

/// TUI view for scanning and importing songs from a selected source path
///
/// Shows real-time progress as songs are scanned and imported:
/// - Progress bar with percentage
/// - Current file being processed
/// - Stats (added, updated, errors)
/// - Cancel option
struct TUISourceScanView: View {
    let dependencies: TUIDependencyContainer
    let sourceId: Int64
    let pathId: Int64
    let path: String
    @Binding var navigationState: NavigationState

    // Scanning state
    @State private var isScanning = false
    @State private var isCancelled = false
    @State private var isComplete = false
    @State private var errorMessage: String?

    // Progress tracking
    @State private var progress: Double = 0.0  // 0.0 to 1.0
    @State private var currentFile: String = ""
    @State private var totalFiles: Int = 0
    @State private var processedFiles: Int = 0

    // Stats
    @State private var addedCount: Int = 0
    @State private var updatedCount: Int = 0
    @State private var errorCount: Int = 0

    var body: some View {
        VStack(spacing: 1) {
            // Header
            HStack {
                Text("Scanning: \(path)")
                Spacer()
            }
            Text("")

            if let error = errorMessage {
                errorView(error)
            } else if isComplete {
                completionView
            } else if isScanning {
                scanningView
            } else {
                startView
            }

            Spacer()
            helpBar
        }
        .onAppear {
            // Auto-start scanning when view appears
            Task { await startScanning() }
        }
        .onKeyPress("c") { cancelScanning() }
        .onKeyPress("\u{1B}") { cancelScanning() }  // Escape key
        .onKeyPress("\r") {  // Enter key
            if isComplete || errorMessage != nil {
                navigationState.pop()
            }
        }
    }

    private var startView: some View {
        VStack {
            Text("Preparing to scan...")
            Text("")
            Text("Press Esc to cancel")
        }
    }

    private var scanningView: some View {
        VStack(spacing: 1) {
            // Progress bar
            HStack {
                Text("Progress: ")
                Text(TUITheme.Icons.music)
                Spacer()
            }
            TUIProgressBar(
                value: progress,
                width: TUITheme.Layout.progressBarWidthWide,
                label: nil,
                showPercentage: true
            )
            Text("")

            // Current file
            HStack {
                Text("Processing (\(processedFiles)/\(totalFiles)):")
                Spacer()
            }
            HStack {
                Text("  ")
                Text(currentFile.isEmpty ? "(gathering files...)" : currentFile)
                Spacer()
            }
            Text("")

            // Stats
            HStack {
                Text(TUIColors.Indicators.success("Added: \(addedCount)"))
                Spacer()
            }
            HStack {
                Text("Updated: \(updatedCount)")
                Spacer()
            }
            if errorCount > 0 {
                HStack {
                    Text(TUIColors.Indicators.error("Errors: \(errorCount)"))
                    Spacer()
                }
            }
        }
    }

    private var completionView: some View {
        VStack(spacing: 1) {
            HStack {
                Text(TUIColors.Indicators.success("Scan Complete!"))
                Spacer()
            }
            Text("")

            HStack {
                Text(TUITheme.Icons.checkmark + " Added: \(addedCount) new songs")
                Spacer()
            }
            HStack {
                Text(TUITheme.Icons.checkmark + " Updated: \(updatedCount) existing songs")
                Spacer()
            }
            if errorCount > 0 {
                HStack {
                    Text(TUITheme.Icons.error + " Errors: \(errorCount)")
                    Spacer()
                }
            }
            Text("")
            HStack {
                Text("Press Enter to continue")
                Spacer()
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            HStack {
                Text(TUIColors.Indicators.error("Scan Failed"))
                Spacer()
            }
            Text("")
            HStack {
                Text(message)
                Spacer()
            }
            Text("")
            HStack {
                Text("Press Enter to go back")
                Spacer()
            }
        }
    }

    private var helpBar: some View {
        VStack(spacing: 0) {
            Text(TUITheme.divider(width: 60))
            HStack {
                if isScanning {
                    Text("[Esc/c] Cancel Scan")
                } else if isComplete || errorMessage != nil {
                    Text("[Enter] Done")
                }
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func startScanning() async {
        guard !isScanning else { return }

        isScanning = true
        isCancelled = false
        isComplete = false
        errorMessage = nil
        progress = 0.0
        currentFile = ""
        addedCount = 0
        updatedCount = 0
        errorCount = 0

        do {
            // Get the SourcePath to scan
            let sourcePathRepo = dependencies.sourcePathRepository
            guard let sourcePath = try await sourcePathRepo.getByPathId(sourceId: sourceId, pathId: pathId) else {
                errorMessage = "Source path not found"
                isScanning = false
                return
            }

            // Get all child paths to count total files
            let allPaths = try await gatherAllPaths(sourcePathRepo: sourcePathRepo, startPath: sourcePath)
            totalFiles = allPaths.count

            // Get song import service
            let songImportService = dependencies.songImportService

            // Track stats
            var addedSongs = 0
            var updatedSongs = 0
            var errors = 0
            var lastProcessedFile = ""

            // Import with progress callback
            try await songImportService.importPaths(
                paths: [sourcePath],
                onProgress: { percent, url async in
                    if Task.isCancelled {
                        return
                    }

                    let newFile = url.lastPathComponent
                    if newFile != lastProcessedFile {
                        lastProcessedFile = newFile
                        addedSongs += 1
                    }

                    await MainActor.run {
                        self.progress = percent / 100.0
                        self.currentFile = newFile
                        self.processedFiles = Int(percent * Double(self.totalFiles) / 100.0)
                        self.addedCount = addedSongs
                        self.updatedCount = updatedSongs
                        self.errorCount = errors
                    }
                }
            )

            // Completion
            isComplete = true
            isScanning = false

        } catch is CancellationError {
            errorMessage = "Scan cancelled by user"
            isScanning = false
        } catch {
            errorMessage = error.localizedDescription
            isScanning = false
        }
    }

    private func cancelScanning() {
        guard isScanning else { return }

        isCancelled = true
        // Cancel the import task
        Task {
            await dependencies.songImportService.cancelImport()
        }
    }

    // MARK: - Helper Methods

    /// Recursively gather all file paths under a directory
    private func gatherAllPaths(sourcePathRepo: SourcePathRepository, startPath: SourcePath) async throws -> [SourcePath] {
        var result = [SourcePath]()

        if startPath.isDirectory {
            let children = try await sourcePathRepo.getByParentId(sourceId: sourceId, parentPathId: startPath.pathId)
            for child in children {
                let childPaths = try await gatherAllPaths(sourcePathRepo: sourcePathRepo, startPath: child)
                result.append(contentsOf: childPaths)
            }
        } else {
            result.append(startPath)
        }

        return result
    }
}
