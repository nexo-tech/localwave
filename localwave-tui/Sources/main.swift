import Foundation

@main
struct LocalWaveTUI {
    static func main() async {
        do {
            let app = try TUIApp()
            try await app.start()
        } catch {
            fputs("❌ Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
