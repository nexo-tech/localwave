import Foundation
import os
import SQLite

class DefaultUserCloudService: UserCloudService {
    let logger = Logger(subsystem: subsystem, category: "UserCloudService")
    func resolveCurrentICloudUser() async throws -> User? {
        if let icloudId = try await iCloudProvider.getCurrentICloudUserID() {
            logger.debug("found cloudID \(icloudId)")
            return try await userService.getOrCreateUser(icloudId: icloudId)
        }
        return nil
    }

    private let userService: UserService
    private let iCloudProvider: ICloudProvider

    public init(userService: UserService, iCloudProvider: ICloudProvider) {
        self.userService = userService
        self.iCloudProvider = iCloudProvider
    }
}
