import SwiftUI

struct SyncView: View {
    @State private var isPickingFolder = false
    @State private var selectedFolderName: String? = nil

    var body: some View {
        VStack {
            // if let folderName = selectedFolderName, isUpd

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

#Preview {
    SyncView()
}
