import AVFoundation
import Foundation
import os

class DefaultUserService: UserService {
    let logger = Logger(subsystem: subsystem, category: "UserService")
    private var userRepository: UserRepository

    func getOrCreateUser(icloudId: Int64) async throws -> User {
        let logger = self.logger
        if let existingUser = try await userRepository.findByIcloudId(icloudId: icloudId) {
            let userId = existingUser.id ?? -1
            logger.debug("found user \(userId) with \(icloudId)")
            return existingUser
        } else {
            let user = User(id: nil, icloudId: icloudId)
            logger.debug("need to setup new user for \(icloudId)")
            return try await userRepository.create(user: user)
        }
    }

    public init(userRepository: UserRepository) {
        self.userRepository = userRepository
    }
}
