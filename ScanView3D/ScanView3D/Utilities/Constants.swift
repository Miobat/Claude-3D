import SwiftUI

enum AppConstants {
    static let appName = "ScanView 3D"
    static let projectsDirectory = "Projects"
    static let scansDirectory = "Scans"
    static let exportDirectory = "Exports"

    enum Colors {
        static let primary = Color("AccentColor")
        static let background = Color(uiColor: .systemBackground)
        static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
        static let scanOverlay = Color.black.opacity(0.6)
        static let measurementLine = Color.yellow
        static let measurementPoint = Color.red
        static let gridColor = Color.gray.opacity(0.3)
    }

    enum Layout {
        static let cornerRadius: CGFloat = 12
        static let padding: CGFloat = 16
        static let smallPadding: CGFloat = 8
        static let iconSize: CGFloat = 24
        static let thumbnailSize: CGFloat = 60
        static let buttonHeight: CGFloat = 44
    }

    enum Scanner {
        static let defaultConfidence: Float = 0.5
        static let maxMeshAnchors: Int = 256
        static let meshUpdateInterval: TimeInterval = 0.1
    }
}
