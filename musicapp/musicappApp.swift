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
            let schemaVersion = 2
            let db = setupSQLiteConnection(dbName: "musicapp\(schemaVersion).sqlite")
            let userRepo = try SQLiteUserRepository(db: db!)
            let userService = DefaultUserService(userRepository: userRepo)
            let icloudProvider = DefaultICloudProvider()
            let userCloudService = DefaultUserCloudService(
                userService: userService, iCloudProvider: icloudProvider)
            let libraryRepo = try SQLiteLibraryRepository(db: db!)
            let libraryService = DefaultLibraryService(libraryRepo: libraryRepo)
            let app = AppDependencies(
                userService: userService,
                userCloudService: userCloudService,
                icloudProvider: icloudProvider,
                libraryService: libraryService)
            return MainTabView(app: app)
        } catch {
            return Text("Failed to initialize the app: \(error.localizedDescription)")
                .foregroundColor(.red)
                .padding()
        }
    }
}
