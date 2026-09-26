import SwiftUI

@main
struct AmazonApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ProductView()
                .environmentObject(store)
                .alert("Something went wrong", isPresented: Binding(
                    get: { store.message != nil }, set: { if !$0 { store.message = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.message ?? "")
                }
        }
    }
}
