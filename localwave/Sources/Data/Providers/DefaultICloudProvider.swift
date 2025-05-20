import Foundation
import os
import SQLite

class DefaultICloudProvider: ICloudProvider {
    let logger = Logger(subsystem: subsystem, category: "ICloudProvider")
    func isICloudAvailable() -> Bool {
        return FileManager.default.ubiquityIdentityToken != nil
    }

    func getCurrentICloudUserID() async throws -> Int64? {
        logger.debug("Attempting to get current iCloud user")
        if let ubiquityIdentityToken = FileManager.default.ubiquityIdentityToken {
            let tokenData = try NSKeyedArchiver.archivedData(
                withRootObject: ubiquityIdentityToken, requiringSecureCoding: true
            )
            let tokenString = tokenData.base64EncodedString()
            let hashed = hashStringToInt64(tokenString)
            logger.debug("Current iCloud user token: \(hashed)")
            return hashed
        } else {
            logger.debug("No iCloud account is signed in.")
            return nil
        }
    }
}
