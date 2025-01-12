import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct TutorialView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Turtle Rock")
                .font(.title)
            HStack {
                Text("Joshua Tree national park")
                Spacer()
                Text("California").font(.subheadline)
            }
        }
        .padding()
    }
}

#Preview {
    TutorialView()
}
