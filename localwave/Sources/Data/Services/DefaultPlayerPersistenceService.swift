import Foundation
import os

actor DefaultPlayerPersistenceService: PlayerPersistenceService {
    private let queueKey = "currentQueue"
    private let currentIndexKey = "currentQueueIndex"
    private let volumeKey = "playerVolume"

    private let songRepo: SongRepository

    init(songRepo: SongRepository) {
        self.songRepo = songRepo
    }

    func getVolume() async -> Float {
        UserDefaults.standard.float(forKey: volumeKey)
    }

    let logger = Logger(subsystem: subsystem, category: "PlayerPersistenceService")

    func restore() async -> ([Song], Int, Song?)? {
        guard let songIds = UserDefaults.standard.array(forKey: queueKey) as? [Int64],
              let currentIndex = UserDefaults.standard.value(forKey: currentIndexKey) as? Int,
              !songIds.isEmpty
        else {
            logger.debug("no persisted data, skipping")
            return nil
        }

        // Need to inject song repository
        logger.debug("loading songs by ids: \(songIds)")
        let songs = await songRepo.getSongs(ids: songIds)
        let currentSong = songs[safe: currentIndex]

        return (songs, currentIndex, currentSong)
    }

    func savePlaybackState(volume: Float, currentIndex: Int, songs: [Song]) async {
        let songIds = songs.map { $0.id ?? -1 }
        UserDefaults.standard.set(songIds, forKey: queueKey)
        UserDefaults.standard.set(currentIndex, forKey: currentIndexKey)
        UserDefaults.standard.set(volume, forKey: volumeKey)
    }
}
