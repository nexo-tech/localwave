//
//  Preview.swift
//  musicapp
//
//  Created by Oleg Pustovit on 06.02.2025.
//
import SwiftUI

#Preview {

    let defaultSong = Song(
        id: 1231, songKey: 3132, artist: "Song Master",
        title: "The music for dogs", album: "x",
        
        albumArtist: "dsad",
        releaseYear: 2022,
        discNumber: 11,
        
        trackNumber: 1, coverArtPath: nil, bookmark: nil,pathHash: -1,
        createdAt: Date(), updatedAt: nil
    )
    VStack {
          MiniPlayerViewInner(
              currentSong: defaultSong,
              onTap: {},
              playPauseAction: {},
              isPlaying: true
          )
    }.applyTheme()

}
