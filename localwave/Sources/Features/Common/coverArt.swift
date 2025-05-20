import SwiftUI

func coverArt(of song: Song) -> UIImage? {
    guard let coverArtPath = song.coverArtPath else { return nil }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let coverURL = docs.appendingPathComponent(coverArtPath)
    return UIImage(contentsOfFile: coverURL.path)
}
