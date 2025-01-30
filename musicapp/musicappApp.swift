//  musicapp
//
//  Created by Oleg Pustovit on 10.01.2025.
//

import SwiftUI

@main
struct musicappApp: App {
    var body: some Scene {
        WindowGroup {
            setupView()
        }
    }

    private func setupView() -> some View {
        do {
            let schemaVersion = 6
            let db = setupSQLiteConnection(dbName: "musicapp\(schemaVersion).sqlite")
            let userRepo = try SQLiteUserRepository(db: db!)
            let userService = DefaultUserService(userRepository: userRepo)
            let icloudProvider = DefaultICloudProvider()
            let userCloudService = DefaultUserCloudService(
                userService: userService, iCloudProvider: icloudProvider)
            let libraryRepo = try SQLiteLibraryRepository(db: db!)
            let libraryPathRepository = try SQLiteLibraryPathRepository(db: db!)
            let libraryPathSearchRepository = try SQLiteLibraryPathSearchRepository(db: db!)
            let librarySyncService = DefaultLibrarySyncService(
                libraryRepository: libraryRepo,
                libraryPathSearchRepository: libraryPathSearchRepository,
                libraryPathRepository: libraryPathRepository)
          let songRepository = try SQLiteSongRepository(db: db!)
          let songImportService = DefaultSongImportService(songRepo: songRepository,
                                                           libraryPathRepo: libraryPathRepository, libraryRepo: libraryRepo)
            let libraryImportService = DefaultLibraryImportService(libraryPathRepository: libraryPathRepository, libraryPathSearchRepository: libraryPathSearchRepository)
            let libraryService = DefaultLibraryService(
                libraryRepo: libraryRepo, librarySyncService: librarySyncService, libraryImportService: libraryImportService)
            let app = AppDependencies(
                userService: userService,
                userCloudService: userCloudService,
                icloudProvider: icloudProvider,
                libraryService: libraryService,
                songRepository:  songRepository,
                songImportService: songImportService)
          let v: some View =  MainTabView(app: app)
          return v
        } catch {
            return Text("Failed to initialize the app: \(error.localizedDescription)")
                .foregroundColor(.red)
                .padding()
        }
    }
}
