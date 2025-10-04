//
//  BasePlayerViewModel.swift
//  localwave
//
//  Created by Claude Code on 04.10.2025.
//

import Combine
import Foundation
import os

/// Platform-agnostic base player view model
/// Contains all business logic that can be shared between iOS and TUI
@MainActor
public class BasePlayerViewModel: ObservableObject, AudioPlayerDelegate {
    // MARK: - Published Properties

    @Published public var currentSong: Song?
    @Published public var isPlaying = false
    @Published public var playbackProgress: Double = 0
    @Published public var currentTime: String = "0:00"
    @Published public var duration: String = "0:00"

    @Published public var volume: Float = 1.0 {
        didSet {
            // Apply logarithmic curve for better human perception
            let actualVolume = volume * volume
            player.volume = actualVolume
            Task {
                await playerPersistenceService?.savePlaybackState(
                    volume: volume, currentIndex: currentIndex, songs: songs
                )
            }
        }
    }

    // MARK: - Internal State

    internal var isShuffleEnabled: Bool = false
    internal var originalQueue: [Song] = []
    internal var repeatMode: RepeatMode = .none

    public var queue: [Song] {
        return songs
    }

    // MARK: - Dependencies

    internal let songRepo: SongRepository?
    internal let playlistRepo: PlaylistRepository
    internal let playlistSongRepo: PlaylistSongRepository
    internal let playerPersistenceService: PlayerPersistenceService?
    internal let player: AudioPlayerProtocol

    internal var timer: Timer?
    internal var songs: [Song] = []
    internal var currentIndex: Int = 0
    internal var activeSecurityScopedURLs = [URL]()

    internal let logger = Logger(subsystem: subsystem, category: "BasePlayerViewModel")

    // MARK: - Initialization

    public init(
        player: AudioPlayerProtocol,
        playerPersistenceService: PlayerPersistenceService? = nil,
        songRepo: SongRepository? = nil,
        playlistRepo: PlaylistRepository,
        playlistSongRepo: PlaylistSongRepository
    ) {
        self.player = player
        self.playerPersistenceService = playerPersistenceService
        self.songRepo = songRepo
        self.playlistRepo = playlistRepo
        self.playlistSongRepo = playlistSongRepo

        self.player.delegate = self

        Task {
            // Restore volume
            if let storedVolume = await self.playerPersistenceService?.getVolume() {
                self.volume = storedVolume
            }

            // Restore queue and current song
            if let (songs, currentIndex, currentSong) = await self.playerPersistenceService?.restore() {
                self.songs = songs
                self.currentIndex = currentIndex
                self.currentSong = currentSong

                if let currentSong = currentSong {
                    stopAndPreloadSong(currentSong)
                }
            }
        }
    }

    // MARK: - AudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AudioPlayerProtocol, successfully: Bool) {
        nextSong()
    }

    // MARK: - Queue Management

    public func addToQueue(_ song: Song) {
        songs.append(song)
        Task {
            await playerPersistenceService?.savePlaybackState(
                volume: volume,
                currentIndex: currentIndex,
                songs: songs
            )
        }
    }

    public func reorderQueue(from source: IndexSet, to destination: Int) {
        songs.move(fromOffsets: source, toOffset: destination)
        if let currentSong = currentSong {
            currentIndex = songs.firstIndex { $0.id == currentSong.id } ?? 0
        }
        Task {
            await playerPersistenceService?.savePlaybackState(
                volume: volume, currentIndex: currentIndex, songs: songs
            )
        }
    }

    public func configureQueue(songs: [Song], startIndex: Int) {
        self.songs = songs
        currentIndex = startIndex
        currentSong = songs[safe: startIndex]
        Task {
            await playerPersistenceService?.savePlaybackState(
                volume: volume, currentIndex: currentIndex, songs: songs
            )
        }
    }

    // MARK: - Playback Control

    public func playSong(_ song: Song) {
        stopAndPreloadSong(song)
        play()
    }

    public func playPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    internal func play() {
        player.play()
        isPlaying = true
        startTimer()
    }

    internal func pause() {
        player.pause()
        isPlaying = false
        stopTimer()
    }

    public func stop() {
        player.stop()
        isPlaying = false
        playbackProgress = 0
        stopTimer()

        if let url = player.url {
            url.stopAccessingSecurityScopedResource()
        }

        activeSecurityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        activeSecurityScopedURLs.removeAll()
    }

    public func previousSong() {
        guard !songs.isEmpty else { return }
        currentIndex = (currentIndex - 1 + songs.count) % songs.count
        playSong(songs[currentIndex])
        Task {
            await playerPersistenceService?.savePlaybackState(
                volume: volume, currentIndex: currentIndex, songs: songs
            )
        }
    }

    public func nextSong() {
        guard !songs.isEmpty else { return }
        let isPlayingLastSong = currentIndex == songs.count - 1

        switch repeatMode {
        case .none:
            if isPlayingLastSong {
                stop()
            } else {
                currentIndex += 1
                playSong(songs[currentIndex])
            }
        case .all:
            currentIndex = isPlayingLastSong ? 0 : currentIndex + 1
            playSong(songs[currentIndex])
        case .one:
            playSong(songs[currentIndex])
        }

        Task {
            await playerPersistenceService?.savePlaybackState(
                volume: volume, currentIndex: currentIndex, songs: songs
            )
        }
    }

    public func seek(to progress: Double) {
        player.currentTime = progress
        updateTimeDisplay()
    }

    public func seekByFraction(_ fraction: Double) {
        player.currentTime = fraction * player.duration
        updateTimeDisplay()
    }

    // MARK: - Shuffle & Repeat

    public func setShuffle(_ enabled: Bool) {
        if enabled {
            if !isShuffleEnabled {
                originalQueue = songs
                if let current = currentSong {
                    var remainingSongs = songs.filter { $0.id != current.id }
                    remainingSongs.shuffle()
                    songs = [current] + remainingSongs
                    currentIndex = 0
                } else {
                    songs.shuffle()
                    currentIndex = 0
                }
            }
        } else {
            if isShuffleEnabled {
                if let current = currentSong, !originalQueue.isEmpty {
                    songs = originalQueue
                    if let index = songs.firstIndex(where: { $0.id == current.id }) {
                        currentIndex = index
                    } else {
                        currentIndex = 0
                        currentSong = songs.first
                    }
                }
                originalQueue = []
            }
        }
        isShuffleEnabled = enabled
    }

    public func setRepeat(_ enabled: RepeatMode) {
        repeatMode = enabled
    }

    // MARK: - Playlist Creation

    public func createPlaylist(name: String) async throws {
        let newPlaylist = Playlist(id: nil, name: name, createdAt: Date(), updatedAt: nil)
        let createdPlaylist = try await playlistRepo.create(playlist: newPlaylist)
        guard let playlistId = createdPlaylist.id else { return }

        for song in songs {
            guard let songId = song.id else { continue }
            try await playlistSongRepo.addSong(playlistId: playlistId, songId: songId)
        }
    }

    // MARK: - Private Helpers

    internal func stopAndPreloadSong(_ song: Song) {
        stop()

        guard let url = resolveSongURL(song) else {
            logger.error("Can't load song URL.")
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            logger.error("Failed to start accessing security scoped resource for song: \(song.title)")
            do {
                let newBookmark = try url.bookmarkData(options: [])
                logger.warning("Renewed bookmark for song: \(song.title)")
                var updatedSong = song
                updatedSong.bookmark = newBookmark
                Task {
                    _ = try await songRepo?.upsertSong(updatedSong)
                }
            } catch {
                logger.error("Failed to renew bookmark: \(error)")
            }
            return
        }
        activeSecurityScopedURLs.append(url)

        do {
            try player.prepareToPlay(url: url)
            player.volume = volume * volume
            currentSong = song
            updateTimeDisplay()
        } catch {
            logger.error("Player init error: \(error)")
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.removeAll { $0 == url }
        }
    }

    internal func resolveSongURL(_ song: Song) -> URL? {
        guard let bookmarkData = song.bookmark else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                let newBookmark = try url.bookmarkData(options: [])
                logger.warning("Bookmark was stale - consider reimporting this file")

                var updatedSong = song
                updatedSong.bookmark = newBookmark
                Task {
                    _ = try await songRepo?.upsertSong(updatedSong)
                }
            }

            return url
        } catch {
            logger.error("Bookmark error: \(error)")
            return nil
        }
    }

    internal func startTimer() {
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimeDisplay()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    internal func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    internal func updateTimeDisplay() {
        playbackProgress = player.currentTime / player.duration
        currentTime = formatTime(player.currentTime)
        duration = formatTime(player.duration)
    }

    internal func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
