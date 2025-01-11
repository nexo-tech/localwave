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
            let db = SetupSQLiteConnection(dbName: "musicapp.sqlite")
            let userRepo = try SQLiteUserRepository(db: db!)
            let userService = DefaultUserService(userRepository: userRepo)
            let app = AppDependencies(userService: userService)
            return MainTabView(app: app)
        } catch {
            return Text("Failed to initialize the app: \(error.localizedDescription)")
                .foregroundColor(.red)
                .padding()
        }
    }
}
