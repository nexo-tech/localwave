import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            FavouritesView().tabItem {
                Label("Favourites", systemImage: "heart.fill")
            }
            PlaylistsView().tabItem {
                Label("Playlists", systemImage: "music.note.list")
            }
            FavouritesView().tabItem {
                Label("Favourites", systemImage: "books.vertical")
            }
            SyncView().tabItem {
                Label("Sync", systemImage: "icloud.and.arrow.down")
            }
        }.accentColor(.orange)
    }
}

#Preview {
    MainTabView()
}
