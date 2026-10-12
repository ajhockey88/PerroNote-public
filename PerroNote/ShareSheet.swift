import SwiftUI
import UIKit

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// The standard iOS share sheet (Outlook, Files, AirDrop and so on).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
