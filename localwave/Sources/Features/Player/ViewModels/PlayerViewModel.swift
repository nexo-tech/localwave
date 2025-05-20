//
//  PlayerViewModel.swift
//  localwave
//
//  Created by Oleg Pustovit on 20.05.2025.
//

import AVFoundation
import Combine
import MediaPlayer
import os
import SwiftUI

@MainActor
class PlayerViewModel: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published var currentSong: Song?
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0
    @Published var currentTime: String = "0:00"
    @Published var duration: String = "0:00"

    private var isShuffleEnabled: Bool = false
    private var originalQueue: [Song] = []
    private var isRepeatEnabled: Bool = false

    var queue: [Song] {
        return songs
    }

    private let songRepo: SongRepository?
    private let playlistRepo: PlaylistRepository
    private let playlistSongRepo: PlaylistSongRepository
    private let playerPersistenceService: PlayerPersistenceService?

    //    init(
    //        playerPersistenceService: PlayerPersistenceService, songRepo: SongRepository,
    //        playlistRepo: PlaylistRepository,
    //        playlistSongRepo: PlaylistSongRepository
    //    ) {
    //      self.playerPersistenceService = playerPersistenceService
    //      self.songRepo = songRepo
    //      super.init()
    //        setupAudioSession()
    //        setupRemoteCommands()
    //        setupInterruptionObserver()
    //
    //    }

    func reorderQueue(from source: IndexSet, to destination: Int) {
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

    func createPlaylist(name: String) async throws {
        let newPlaylist = Playlist(id: nil, name: name, createdAt: Date(), updatedAt: nil)
        let createdPlaylist = try await playlistRepo.create(playlist: newPlaylist)
        guard let playlistId = createdPlaylist.id else { return }

        for song in songs {
            guard let songId = song.id else { continue }
            try await playlistSongRepo.addSong(playlistId: playlistId, songId: songId)
        }
    }

    @Published var volume: Float = 0.5 { // default volume now 0.5
        didSet {
            player?.volume = volume
            Task {
                await playerPersistenceService?.savePlaybackState(
                    volume: volume, currentIndex: currentIndex, songs: songs
                )
            }
        }
    }

    init(
        playerPersistenceService: PlayerPersistenceService? = nil,
        songRepo: SongRepository? = nil,
        playlistRepo: PlaylistRepository,
        playlistSongRepo: PlaylistSongRepository
    ) {
        self.playerPersistenceService = playerPersistenceService
        self.songRepo = songRepo
        self.playlistRepo = playlistRepo
        self.playlistSongRepo = playlistSongRepo
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupInterruptionObserver()

        Task {
            if let (songs, currentIndex, currentSong) = await self.playerPersistenceService?
                .restore()
            {
                self.songs = songs
                self.currentIndex = currentIndex
                self.currentSong = currentSong

                if let currentSong = currentSong {
                    stopAndPreloadSong(currentSong)
                }
            }

            if let stored = await self.playerPersistenceService?.getVolume() {
                self.volume = stored - 0.5
            }
        }
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var songs: [Song] = []
    private var currentIndex: Int = 0

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        nextSong()
    }

    func addToQueue(_ song: Song) {
        songs.append(song)
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume,
                currentIndex: self.currentIndex,
                songs: self.songs
            )
        }
    }

    func configureQueue(songs: [Song], startIndex: Int) {
        self.songs = songs
        currentIndex = startIndex
        currentSong = songs[safe: startIndex]
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume, currentIndex: self.currentIndex, songs: self.songs
            )
        }
    }

    var logger = Logger(subsystem: subsystem, category: "PlayerViewModel")

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("audio session setup error: \(error)")
        }
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.playPause()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextSong()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousSong()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        // Enable commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }

    func updateNowPlayingInfo() {
        guard let song = currentSong, let player = player else { return }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? player.rate : 0.0

        if let artwork = coverArt(of: song) {
            let mpArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = mpArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .began {
            pause()
        } else if type == .ended {
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    play()
                }
            }
        }
    }

    private func stopAndPreloadSong(_ song: Song) {
        stop()

        guard let url = resolveSongURL(song) else {
            logger.error("Can't load song URL.")
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            logger.error(
                "Failed to start accessing security scoped resource for song: \(song.title)")
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
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            player = audioPlayer
            player?.volume = volume
            currentSong = song
            player?.delegate = self
            updateTimeDisplay()
        } catch {
            logger.error("Player init error: \(error)")
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.removeAll { $0 == url }
        }
    }

    func playSong(_ song: Song) {
        stopAndPreloadSong(song)

        play()
        updateNowPlayingInfo()
    }

    func playPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    private func play() {
        player?.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
    }

    private var activeSecurityScopedURLs = [URL]()
    func stop() {
        player?.stop()
        isPlaying = false
        playbackProgress = 0
        stopTimer()

        if let url = player?.url {
            url.stopAccessingSecurityScopedResource()
        }

        // Release all security scoped accesses
        activeSecurityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        activeSecurityScopedURLs.removeAll()
    }

    func previousSong() {
        guard !songs.isEmpty else { return }
        currentIndex = (currentIndex - 1 + songs.count) % songs.count
        playSong(songs[currentIndex])
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume, currentIndex: self.currentIndex, songs: self.songs
            )
        }
    }

    func nextSong() {
        guard !songs.isEmpty else { return }
        if currentIndex + 1 < songs.count {
            currentIndex += 1
            playSong(songs[currentIndex])
        } else {
            if isRepeatEnabled {
                currentIndex = 0
                playSong(songs[currentIndex])
            } else {
                stop()
            }
        }
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume, currentIndex: self.currentIndex, songs: self.songs
            )
        }
    }

    func seek(to progress: Double) {
        guard let player = player else { return }

        player.currentTime = progress
        updateTimeDisplay()
    }

    func setShuffle(_ enabled: Bool) {
        if enabled {
            if !isShuffleEnabled {
                originalQueue = songs // preserve original order
                if let current = currentSong {
                    var remainingSongs = songs.filter { $0.id != current.id }
                    remainingSongs.shuffle()
                    songs = [current] + remainingSongs // keep current song at index 0
                    currentIndex = 0
                } else {
                    songs.shuffle()
                    currentIndex = 0
                }
                updateNowPlayingInfo()
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
                updateNowPlayingInfo()
            }
        }
        isShuffleEnabled = enabled
    }

    func setRepeat(_ enabled: Bool) {
        isRepeatEnabled = enabled
    }

    func seekByFraction(_ fraction: Double) {
        guard let player = player else { return }
        // Multiply the fraction (0...1) by the total duration to get the desired time.
        player.currentTime = fraction * player.duration
        updateTimeDisplay()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimeDisplay()
            }
        }

        // Ensure timer runs on main run loop
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTimeDisplay() {
        guard let player = player else { return }

        playbackProgress = player.currentTime / player.duration
        currentTime = formatTime(player.currentTime)
        duration = formatTime(player.duration)
        updateNowPlayingInfo()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func resolveSongURL(_ song: Song) -> URL? {
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

                // Update the song in repository
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
}
