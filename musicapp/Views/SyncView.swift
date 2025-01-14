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
    @StateObject private var syncViewModel: SyncViewModel
    @State var isPickingFolder = false
    @State var pickedFolder: String? = nil

    private let logger = Logger(subsystem: subsystem, category: "SyncView")

    init(
        userCloudService: UserCloudService?,
        icloudProvider: ICloudProvider?,
        libraryService: LibraryService?
    ) {
        _syncViewModel = StateObject(
            wrappedValue: SyncViewModel(
                userCloudService: userCloudService,
                icloudProvider: icloudProvider,
                libraryService: libraryService))
    }

    var body: some View {
        VStack{
            switch syncViewModel.state {
            case .noICloud:
                SelectFolderView(
                    title: "No ICLOUD",
                    message: "this tab requires iCloud",
                    backgroundColor: Color.orange,
                    iconName: "xmark.circle.fill"
                )
            case .isInitialising:
                VStack {
                    Text("Loading...")
                }.onAppear {
                    logger.debug("running sync view model")
                    syncViewModel.initialise()
                }
            case .noLibraryDirSet:
                SelectFolderView(
                    onAction: {
                        logger.debug("attempting to click")
                        isPickingFolder = true
                    },
                    backgroundColor: Color.purple
                ).fileImporter(
                    isPresented: $isPickingFolder,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls) where urls.count != 0:
                        if let singleUrl = urls.first {
                            self.pickedFolder = singleUrl.absoluteString
                        } else {
                            logger.debug("couldn't get url")
                        }
                    default:
                        logger.debug("couldn't get url")
                    }
                }
            case .notSyncedYet:
                VStack {
                    let selectedFolderName = syncViewModel.selectedFolderName ?? ""
                    Text("not synced: \(selectedFolderName)")
                    Text("Plase start")
                    Button("Sync now") {
                        syncViewModel.sync()
                    }
                }
            case .showTreeView:
                VStack {
                    let totalFiles = syncViewModel.currentLibrary?.totalPaths ?? 0
                    Text("Tree view! \(totalFiles)")
                    Button("Sync now") {
                        syncViewModel.sync()
                    }
                }
            case .syncInProgress:
                VStack {
                    Text("syncing")
                    if let currentDir = syncViewModel.currentSyncedDir {
                        Text("curr: \(currentDir)")
                    }
                }
            case .unboundView:
                VStack {
                    Text("unknown state")
                }
            }
        }.onChange(of: pickedFolder){
            if let pickedFolder = pickedFolder {
                syncViewModel.registerPath(pickedFolder)
                logger.debug("updated path")
            } else {
                logger.debug("no path")
            }
        }
    }
}

enum SyncViewState {
    case noICloud, isInitialising,
        noLibraryDirSet, notSyncedYet,
        showTreeView, syncInProgress, unboundView
}

@MainActor
class SyncViewModel: ObservableObject {
    @Published var createdUser: User?
    @Published var errorMessage: String?

    @Published var selectedFolderName: String? = nil
    @Published var currentLibrary: Library?
    @Published var isSyncing = false
    @Published var currentSyncedDir: String? = nil

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
        } else if createdUser != nil && currentLibrary == nil {
            return .noLibraryDirSet
        } else if createdUser != nil && currentLibrary != nil && currentLibrary?.lastSyncedAt == nil
            && !isSyncing
        {
            return .notSyncedYet
        } else if createdUser != nil && currentLibrary != nil && currentLibrary?.lastSyncedAt != nil
            && !isSyncing
        {
            return .showTreeView
        } else if isSyncing {
            return .syncInProgress
        }

        return .unboundView
    }
    let logger = Logger(subsystem: subsystem, category: "SyncViewModel")

    func registerPath(_ path: String) {
        Task {
            logger.debug("registering \(path)")
            do {
                if let currentUser = self.createdUser {
                    let lib = try await libraryService?.registerLibraryPath(
                        userId: currentUser.id!, path: path)
                    let libId = lib?.id ?? -1
                    logger.debug("created library \(libId)")
                    self.currentLibrary = lib
                }
            } catch {
                logger.debug("failed to register lib \(error.localizedDescription)")
            }
            
            logger.debug("library is set...")
        }
    }

    func sync() {
        Task {
            self.isSyncing = true
            var currentLib = self.currentLibrary
            do {
                // Start syncing with updates
                let folderPath = currentLibrary?.dirPath
                let libraryId = currentLibrary?.id
                logger.debug("started syncing...")
                if folderPath != nil && libraryId != nil {
                    let result = try await libraryService?.syncService().syncDir(
                        libraryId: libraryId!, folderURL: URL(string: folderPath!)!,
                        onCurrentURL: { url in
                            DispatchQueue.main.async {
                                
                                self.currentSyncedDir = url?.absoluteString
                                
                            }
                        },
                        onSetLoading: { loading in
                            DispatchQueue.main.async {
                                
                                self.isSyncing = loading
                            }
                        })
                    currentLib?.totalPaths = result?.totalPaths
                } else {
                    logger.error("failed to sync")
                }
                self.isSyncing = false
                currentLib?.lastSyncedAt = Date()
                currentLib = try await libraryService?.repository().updateLibrary(
                    library: currentLib!)
                logger.debug("finished syncing...")
                self.currentLibrary = currentLib
            } catch {
                self.isSyncing = false
                currentLib?.lastSyncedAt = Date()
                currentLib?.syncError = error.localizedDescription
                currentLib = try await libraryService?.repository().updateLibrary(
                    library: currentLib!)
                logger.debug("finished with error")
                self.currentLibrary = currentLib
            }
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
                if let user = user {
                    self.currentLibrary = try await libraryService?.getCurrentLibrary(
                        userId: user.id!)
                    self.selectedFolderName = self.currentLibrary?.dirPath
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SyncView(userCloudService: nil, icloudProvider: nil, libraryService: nil)
}
