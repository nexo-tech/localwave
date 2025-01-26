import SwiftUI
import Combine

// MARK: - Random Name Generator
struct NameGenerator {
    static let folderNames = ["Documents", "Photos", "Music", "Videos", "Projects", "Downloads", "Archives", "Work", "Personal"]
    static let fileNames = ["Report.docx", "Image.png", "Song.mp3", "Video.mov", "Presentation.pptx", "Spreadsheet.xlsx", "Notes.txt", "Archive.zip", "Project.swift"]

    static func randomFolderName() -> String {
        folderNames.randomElement() ?? "Folder"
    }

    static func randomFileName() -> String {
        fileNames.randomElement() ?? "File.txt"
    }
}

// MARK: - Model
class FileSystemItem: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let isFolder: Bool

    @Published var children: [FileSystemItem]? = nil

    init(name: String, isFolder: Bool, children: [FileSystemItem]? = nil) {
        self.name = name
        self.isFolder = isFolder
        self.children = children
    }
}

// MARK: - ViewModel
class FileSystemViewModel: ObservableObject {
    @Published var rootItems: [FileSystemItem] = []
    @Published var expandedItems: Set<UUID> = []

    init() {
        loadRootItems()
    }

    func loadRootItems() {
        // Initialize with random root items
        rootItems = [
            FileSystemItem(name: NameGenerator.randomFolderName(), isFolder: true),
            FileSystemItem(name: NameGenerator.randomFileName(), isFolder: false),
            FileSystemItem(name: NameGenerator.randomFolderName(), isFolder: true),
            FileSystemItem(name: NameGenerator.randomFileName(), isFolder: false)
        ]
    }

    func toggleExpansion(for item: FileSystemItem) {
        if expandedItems.contains(item.id) {
            // Collapse the folder
            expandedItems.remove(item.id)
        } else {
            // Expand the folder
            expandedItems.insert(item.id)
            loadChildrenIfNeeded(for: item)
        }
    }

    private func loadChildrenIfNeeded(for folder: FileSystemItem) {
        guard folder.isFolder, folder.children == nil else { return }

        // Simulate asynchronous loading
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            let numberOfChildren = Int.random(in: 2...5)
            var fetchedChildren: [FileSystemItem] = []

            for _ in 0..<numberOfChildren {
                let isFolder = Bool.random()
                let name = isFolder ? NameGenerator.randomFolderName() : NameGenerator.randomFileName()
                fetchedChildren.append(FileSystemItem(name: name, isFolder: isFolder))
            }

            DispatchQueue.main.async {
                folder.children = fetchedChildren
            }
        }
    }

    func isExpanded(_ item: FileSystemItem) -> Bool {
        expandedItems.contains(item.id)
    }
}

// MARK: - Views
struct FileSystemTreeView: View {
    @StateObject private var viewModel = FileSystemViewModel()

    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.rootItems) { item in
                    FileSystemItemView(item: item, viewModel: viewModel, depth: 0)
                }
            }
            .navigationTitle("File System")
            .listStyle(PlainListStyle()) // Cleaner list style
        }
    }
}

struct FileSystemItemView: View {
    @ObservedObject var item: FileSystemItem
    @ObservedObject var viewModel: FileSystemViewModel
    var depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if item.isFolder {
                    Button(action: {
                        viewModel.toggleExpansion(for: item)
                    }) {
                        Image(systemName: viewModel.isExpanded(item) ? "folder.open.fill" : "folder.fill")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle()) // Remove default button styling
                } else {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.gray)
                }

                Text(item.name)
                    .foregroundColor(item.isFolder ? .primary : .secondary)
                    .onTapGesture {
                        if item.isFolder {
                            viewModel.toggleExpansion(for: item)
                        }
                    }

                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 20) // Indentation based on depth
            .padding(.vertical, 4) // Increased vertical padding for more space

            // Show children if expanded
            if viewModel.isExpanded(item) {
                if let children = item.children {
                    ForEach(children) { child in
                        FileSystemItemView(item: child, viewModel: viewModel, depth: depth + 1)
                    }
                } else {
                    // Show a loading indicator while children are being fetched
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8, anchor: .center)
                        Text("Loading...")
                            .foregroundColor(.gray)
                    }
                    .padding(.leading, CGFloat(depth + 1) * 20)
                }
            }
        }
    }
}

// MARK: - Preview
struct FileSystemTreeView_Previews: PreviewProvider {
    static var previews: some View {
        FileSystemTreeView()
    }
}
