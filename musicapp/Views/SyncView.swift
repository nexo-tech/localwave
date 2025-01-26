import SwiftUI
import os
@MainActor
class LibraryBrowseViewModel: ObservableObject {
    private let service: LibraryImportService
    private let libraryId: Int64
    
    /// A stack of visited parentPathIds; the last element is the "current folder."
    @Published private var pathStack: [Int64?] = [nil]

    @Published var items: [LibraryPath] = []
    @Published var searchTerm: String = ""
    
    /// For checkboxes on any item (folders or files).
    @Published var selectedPathIds = Set<Int64>()

    /// The current parent path we’re displaying.
    var parentPathId: Int64? {
        pathStack.last ?? nil
    }

    /// Whether we can go back one level.
    var canGoBack: Bool {
        pathStack.count > 1
    }

    init(service: LibraryImportService, libraryId: Int64, initialParentPathId: Int64? = nil) {
        self.service = service
        self.libraryId = libraryId
        if let initialParent = initialParentPathId {
            pathStack = [nil, initialParent]
        }
    }

    func loadItems() async {
        do {
            if searchTerm.isEmpty {
                items = try await service.listItems(libraryId: libraryId, parentPathId: parentPathId)
            } else {
                items = try await service.search(libraryId: libraryId, query: searchTerm)
            }
        } catch {
            print("Load items error: \(error)")
        }
    }

    /// Navigate into a subfolder (push on stack).
    func goIntoFolder(with pathId: Int64) {
        pathStack.append(pathId)
        searchTerm = ""
        Task { await loadItems() }
    }

    /// Go up one level (pop from stack).
    func goBack() {
        guard canGoBack else { return }
        pathStack.removeLast()
        searchTerm = ""
        Task { await loadItems() }
    }

    /// Toggle selection for a path (folder or file).
    func toggleSelection(_ pathId: Int64) {
        if selectedPathIds.contains(pathId) {
            selectedPathIds.remove(pathId)
        } else {
            selectedPathIds.insert(pathId)
        }
    }
}
struct LibraryBrowseView: View {
    @StateObject var viewModel: LibraryBrowseViewModel

    init(libraryId: Int64,
         parentPathId: Int64? = nil,
         libraryImportService: LibraryImportService) {
        _viewModel = StateObject(
            wrappedValue: LibraryBrowseViewModel(
                service: libraryImportService,
                libraryId: libraryId,
                initialParentPathId: parentPathId
            )
        )
    }

    var body: some View {
        NavigationView {
            VStack {
                // Top bar with optional "Back" button
                HStack {
                    if viewModel.canGoBack {
                        Button("Back") {
                            viewModel.goBack()
                        }
                        .padding(.leading)
                    }
                    Spacer()
                }
                
                // Search bar
                TextField("Search...", text: $viewModel.searchTerm)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .onSubmit {
                        Task { await viewModel.loadItems() }
                    }

                // File/Folder list
                List(viewModel.items, id: \.pathId) { item in
                    HStack {
                        // Icon: folder or doc
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(item.isDirectory ? .blue : .gray)

                        // Name + relative path
                        VStack(alignment: .leading) {
                            Text(item.name)
                                .fontWeight(.medium)
                            Text(item.relativePath)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Checkboxes on everything (folder or file)
                        Button {
                            viewModel.toggleSelection(item.pathId)
                        } label: {
                            Image(systemName: viewModel.selectedPathIds.contains(item.pathId)
                                  ? "checkmark.square"
                                  : "square")
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    .contentShape(Rectangle()) // Entire row is tappable
                    .onTapGesture {
                        if item.isDirectory {
                            viewModel.goIntoFolder(with: item.pathId)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Library Browser")
        }
        .onAppear {
            Task { await viewModel.loadItems() }
        }
    }
}
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
        VStack {
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
                        if let folderURL = urls.first {
                            do {
                                try self.syncViewModel.registerBookmark(folderURL)
                                self.pickedFolder = folderURL.absoluteString
                            } catch {
                                logger.debug("picker error \(error)")
                            }
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
                    Text("file select view! \(totalFiles)")
                    Button("Sync now") {
                        syncViewModel.sync()
                    }
                    Button("resync") {
                        logger.debug("attempting to click")
                        isPickingFolder = true
                    }
                    .padding(20)
                    .fileImporter(
                        isPresented: $isPickingFolder,
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        switch result {
                        case .success(let urls) where urls.count != 0:
                            if let folderURL = urls.first {
                                do {
                                    try self.syncViewModel.registerBookmark(folderURL)
                                    self.pickedFolder = folderURL.absoluteString
                                } catch {
                                    logger.debug("picker error \(error)")
                                }
                            } else {
                                logger.debug("couldn't get url")
                            }
                        default:
                            logger.debug("couldn't get url")
                        }
                    }
                    if let library = syncViewModel.currentLibrary,
                        let ls = syncViewModel.libraryService
                    {
                        let libraryId = library.id
                        let parentPathId = hashStringToInt64(library.dirPath)
                        LibraryBrowseView(
                            libraryId: libraryId!, parentPathId: parentPathId,
                            libraryImportService: ls.importService())
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
        }.onChange(of: pickedFolder) {
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
    let libraryService: LibraryService?

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

    func registerBookmark(_ folderURL: URL) throws {
        guard folderURL.startAccessingSecurityScopedResource() else {
            print("Unable to access security scoped resource.")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        let bookmarkKey = String(hashStringToInt64(folderURL.absoluteString))
        let bookmarkData = try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
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
                    let id = self.currentLibrary?.id ?? -1
                    let path = self.currentLibrary?.dirPath ?? ""
                    logger.debug("library \(id), path: \(path)")
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
