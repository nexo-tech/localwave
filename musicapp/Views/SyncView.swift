import SwiftUI
import os

struct SelectFolderView: View {
    var onAction: (() -> Void)?
    var title: String = "Load your directory"
    var message: String = "Get your iCloud directory and play music"
    var backgroundColor: Color = Color.purple
    var iconName: String = "cloud.fill"

    var body: some View {
        VStack {
            HStack(alignment: .center) {
                Spacer()
                Image(systemName: iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 200)
                    .foregroundColor(backgroundColor)
                Spacer()
            }.frame(maxHeight: .infinity)
            VStack {
                VStack(alignment: .center) {
                    Text(title).font(.title).padding(.bottom, 30).foregroundColor(
                        Color.white)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)  // Align text to center
                    HStack {
                        Spacer()
                    }

                    Spacer()
                    if let onButtonTap = onAction {
                        Button(action: {
                            onButtonTap()
                        }) {
                            Text("Load")
                                .font(.title)
                                .padding()
                                .frame(maxWidth: .infinity)  // Makes the button take full width
                                .background(Color.white)  // White background
                                .foregroundColor(backgroundColor)  // Blue text for contrast
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(50)
                .background(backgroundColor)
                .cornerRadius(25)
                .shadow(radius: 4)
            }.padding(20)
        }
    }
}

struct SyncView: View {
    @State private var isPickingFolder = false
    @State private var selectedFolderName: String? = nil
    @StateObject private var syncViewModel: SyncViewModel

    private let logger = Logger(subsystem: subsystem, category: "SyncView")

    init(userCloudService: UserCloudService?, icloudProvider: ICloudProvider?) {
        _syncViewModel = StateObject(
            wrappedValue: SyncViewModel(
                userCloudService: userCloudService, icloudProvider: icloudProvider))
    }

    var body: some View {
        if syncViewModel.hasICloud() && syncViewModel.createdUser == nil {
            VStack {
                Text("Loading...")
            }.onAppear {
                logger.debug("running sync view model")
                syncViewModel.initialise()
            }
        } else if syncViewModel.hasICloud() && syncViewModel.createdUser != nil {
            SelectFolderView(
                onAction: {
                    isPickingFolder = true
                },
                backgroundColor: Color.purple
            ).fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                print(result)
            }
        } else {
            SelectFolderView(
                title: "No ICLOUD",
                message: "this tab requires iCloud",
                backgroundColor: Color.orange,
                iconName: "xmark.circle.fill"
            )
        }
    }
}

enum SyncViewState {
    case noICloud, isInitialising, noLibraryDirSet
}

class SyncViewModel: ObservableObject {
    @Published var createdUser: User?
    @Published var errorMessage: String?

    private let userCloudService: UserCloudService?
    private let icloudProvider: ICloudProvider?
    private let libraryService: LibraryService?

    init(
        userCloudService: UserCloudService?,
        icloudProvider: ICloudProvider?,
        libraryService: LibraryService?
    ) {
        self.userCloudService = userCloudService
        self.icloudProvider = icloudProvider
        self.libraryService = libraryService
    }

    var state: SyncViewState {
        if !hasICloud() {
            return .noICloud
        } else if hasICloud() && (createdUser == nil && errorMessage == nil) {
            return .isInitialising
        }

    }

    func hasICloud() -> Bool {
        return icloudProvider?.isICloudAvailable() ?? false
    }

    func initialise() {
        if userCloudService == nil {
            self.errorMessage = "service is not available"
        }
        Task { @MainActor in
            do {
                let user = try await userCloudService?.resolveCurrentICloudUser()
                self.createdUser = user
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SyncView(userCloudService: nil, icloudProvider: nil)
}
