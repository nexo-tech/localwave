import SwiftUI

struct MainTabView: View {
    private let app: AppDependencies?
    init(app: AppDependencies?) {
        self.app = app
    }
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
            VStack {
                SyncView(
                    userCloudService: app?.userCloudService,
                    icloudProvider: app?.icloudProvider,
                    libraryService: app?.libraryService)
            }.tabItem {
                Label("Sync", systemImage: "icloud.and.arrow.down")
            }
        }.accentColor(.orange)
    }
}

#Preview {
    MainTabView(app: nil)
}
