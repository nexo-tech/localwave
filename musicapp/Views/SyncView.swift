import SwiftUI
import os

struct SyncView: View {
    private let logger = Logger(subsystem: subsystem, category: "SyncView")
    @State private var isPickingFolder = false
    @State private var selectedFolderName: String? = nil
    @StateObject private var syncViewModel: SyncViewModel

    init(userCloudService: UserCloudService?) {
        _syncViewModel = StateObject(
            wrappedValue: SyncViewModel(userCloudService: userCloudService))
    }

    var body: some View {
        VStack {
            if let err = syncViewModel.errorMessage {
                Text(err).colorInvert()
            } else {
                let userId = syncViewModel.createdUser?.id ?? -1
                Text("User \(userId)")
            }
            Spacer()

        }.onAppear {
            logger.debug("running sync view model")
            syncViewModel.initialise()
        }.padding()
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                print(result)
            }
        Text("sync").font(.largeTitle).foregroundColor(.purple)
    }
}

class SyncViewModel: ObservableObject {
    @Published var createdUser: User?
    @Published var errorMessage: String?

    private let userCloudService: UserCloudService?

    init(userCloudService: UserCloudService?) {
        self.userCloudService = userCloudService
    }

    func initialise() {
        if userCloudService == nil {
            self.errorMessage = "service is not available"
        }
        Task {
            do {
                let user = try await userCloudService?.resolveCurrentICloudUser()
                DispatchQueue.main.async {

                    self.createdUser = user
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
