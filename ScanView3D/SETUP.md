# ScanView 3D - iOS LiDAR Scanner & 3D Viewer

A native iOS app that combines LiDAR 3D scanning with a full-featured 3D model viewer.

## Requirements

- **Mac** with Xcode 15.0+
- **iPhone 12 Pro or newer Pro model** (for LiDAR scanning)
- **iOS 17.0+**
- Apple Developer account (free account works for personal device testing)

## Quick Setup

### Option A: Open the Generated Project (Recommended first try)

1. Clone/copy this repository to your Mac
2. Open `ScanView3D/ScanView3D.xcodeproj` in Xcode
3. Select your development team in **Signing & Capabilities**
4. Connect your iPhone and select it as the build target
5. Build and run (Cmd+R)

### Option B: Create Fresh Xcode Project (If Option A has issues)

If the generated `.xcodeproj` doesn't work perfectly with your Xcode version:

1. Open Xcode → **File → New → Project**
2. Choose **iOS → App**
3. Settings:
   - Product Name: `ScanView3D`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None**
4. Save the project in the `ScanView3D` folder
5. **Delete** the auto-generated `ContentView.swift` and `ScanView3DApp.swift`
6. **Drag** all `.swift` files from the `ScanView3D/ScanView3D/` folder into the Xcode project navigator
7. **Replace** the auto-generated `Assets.xcassets` with the one from this project
8. **Copy** `Info.plist` values into your project's Info tab
9. Build and run

### Important: Code Signing

1. In Xcode, select the **ScanView3D** target
2. Go to **Signing & Capabilities**
3. Check **Automatically manage signing**
4. Select your **Team** (Apple ID)
5. Change the **Bundle Identifier** to something unique (e.g., `com.yourname.scanview3d`)

## Features

### LiDAR Scanner
- Real-time 3D mesh capture using iPhone LiDAR
- Live mesh visualization overlay
- Adjustable mesh detail (Low/Medium/High)
- Texture and color capture from camera
- Surface classification (walls, floors, furniture, etc.)
- Pause/resume scanning
- Depth-based point cloud generation

### 3D Model Viewer
- Load and display OBJ files
- Interactive orbit, pan, and zoom controls
- Configurable lighting
- Grid overlay
- Wireframe mode
- Model information display (vertices, faces, dimensions)

### Measurement Tool
- Tap-to-measure distances on 3D models
- Multiple measurement units (meters, feet, cm, inches)
- Visual measurement markers and lines
- Multiple simultaneous measurements

### Project Management
- Organize scans into projects
- Import existing OBJ files
- Rename and delete scans/projects
- Export and share OBJ files
- File size and scan statistics

## Architecture

```
ScanView3D/
├── ScanView3DApp.swift          # App entry point
├── ContentView.swift            # Tab navigation
├── Info.plist                   # Permissions & capabilities
├── Models/
│   └── Project.swift            # Data models (Project, Scan, Settings)
├── Views/
│   ├── Scanner/
│   │   ├── ScannerView.swift    # Scanner UI with controls
│   │   └── ARScannerView.swift  # ARKit view wrapper
│   ├── Viewer/
│   │   ├── ModelViewerView.swift # 3D viewer with tools
│   │   └── SceneKitView.swift   # SceneKit rendering
│   ├── Projects/
│   │   ├── ProjectListView.swift    # Project list
│   │   └── ProjectDetailView.swift  # Project detail/scans
│   └── Shared/
│       └── SettingsView.swift   # App settings
├── Services/
│   ├── LiDARScanner.swift       # ARKit LiDAR scanning
│   ├── MeshProcessor.swift      # Mesh processing & conversion
│   ├── OBJExporter.swift        # OBJ/PLY file export
│   └── StorageManager.swift     # Persistent storage
└── Utilities/
    ├── Constants.swift          # App constants
    └── Extensions.swift         # Swift extensions
```

## Key Frameworks Used

- **ARKit** - LiDAR scanning and scene reconstruction
- **RealityKit** - AR view and mesh visualization
- **SceneKit** - 3D model viewing and rendering
- **SwiftUI** - User interface
- **Combine** - Reactive state management

## Troubleshooting

### "LiDAR Not Available"
- LiDAR requires iPhone 12 Pro, 13 Pro, 14 Pro, 15 Pro, or 16 Pro
- iPad Pro (2020+) also has LiDAR
- Regular (non-Pro) models don't have LiDAR

### Build Errors
- Ensure deployment target is iOS 17.0+
- Ensure you're building for a physical device (not simulator) for AR features
- Clean build folder (Cmd+Shift+K) and rebuild

### Camera Permission
- The app requires camera permission for scanning
- If denied, go to Settings → ScanView 3D → Camera → Allow

### Signing Issues
- Use your Apple ID as the development team
- Change the bundle identifier to be unique
- Enable "Automatically manage signing"
