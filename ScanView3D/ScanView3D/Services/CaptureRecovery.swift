import Foundation
import Combine

struct CaptureDraft: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var checkpointAt: Date
    var geometryCheckpointAt: Date?
    var name: String
    var settings: ScanSettings
    var photoFolderName: String?
    var location: CaptureLocation?
    var isFinalized: Bool
}

/// Photos remain in Documents/Captures; checkpoint payloads live separately so
/// photogrammetry input directories contain images only. All large I/O is serial.
final class CaptureRecovery: ObservableObject {
    @Published private(set) var drafts: [CaptureDraft] = []
    @Published private(set) var warning: String?
    private let queue = DispatchQueue(label: "scanview.capture.recovery", qos: .utility)
    private let documents: URL
    private var root: URL { documents.appendingPathComponent("CaptureRecovery") }
    private typealias Store = CaptureCheckpointStore<CaptureDraft, MeshData>

    init(documents: URL? = nil) {
        self.documents = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        refresh()
    }

    private func store(_ id: UUID) -> Store { Store(directory: root.appendingPathComponent(id.uuidString)) }

    private func checkedDirectory(_ id: UUID) throws -> URL {
        let checkedRoot = try LibraryFileSafety.child("CaptureRecovery", of: documents)
        return try LibraryFileSafety.child(id.uuidString, of: checkedRoot)
    }

    func begin(name: String, settings: ScanSettings, photos: URL?) throws -> CaptureDraft {
        let now = Date()
        let draft = CaptureDraft(id: UUID(), startedAt: now, checkpointAt: now, name: name,
                                 settings: settings, photoFolderName: photos?.lastPathComponent,
                                 location: nil, isFinalized: false)
        // Small bootstrap only; ensures successfully saved photos are discoverable
        // even if the app dies before the first geometry checkpoint.
        _ = try checkedDirectory(draft.id)
        try store(draft.id).save(draft, payload: nil)
        refresh()
        return draft
    }

    func checkpoint(_ draft: CaptureDraft, mesh: MeshData?, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result {
                _ = try self.checkedDirectory(draft.id)
                try self.store(draft.id).save(draft, payload: mesh)
            }
            DispatchQueue.main.async { self.refresh(); completion(result) }
        }
    }

    func load(_ draft: CaptureDraft, completion: @escaping (Result<(CaptureDraft, MeshData?), Error>) -> Void) {
        queue.async {
            let result = Result {
                _ = try self.checkedDirectory(draft.id)
                let loaded = try self.store(draft.id).load()
                guard loaded.0.id == draft.id else { throw CocoaError(.fileReadCorruptFile) }
                if let mesh = loaded.1 {
                    guard mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                          mesh.normals.isEmpty || mesh.normals.count == mesh.vertices.count,
                          mesh.colors.isEmpty || mesh.colors.count == mesh.vertices.count,
                          mesh.faces.allSatisfy({ $0.count == 3 && $0.allSatisfy { Int($0) < mesh.vertices.count } }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
                return loaded
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func photoFolder(for draft: CaptureDraft) -> URL? {
        guard let name = draft.photoFolderName, UUID(uuidString: name) != nil else { return nil }
        guard let captures = try? LibraryFileSafety.child("Captures", of: documents),
              let folder = try? LibraryFileSafety.child(name, of: captures) else { return nil }
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// Only called after a successful save or explicit confirmation to discard.
    /// The capture workers must already have drained before deleting photos.
    func discard(_ draft: CaptureDraft) {
        queue.async {
            do {
                let directory = try self.checkedDirectory(draft.id)
                // Never follow a replaced photo/pose reference during cleanup.
                if let name = draft.photoFolderName {
                    guard UUID(uuidString: name) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    let captures = try LibraryFileSafety.child("Captures", of: self.documents)
                    _ = try LibraryFileSafety.child(name, of: captures)
                    _ = try LibraryFileSafety.child(name + PoseFile.suffix, of: captures)
                }
                if let folder = self.photoFolder(for: draft) {
                    try FileManager.default.removeItem(at: folder)
                    let poses = PoseFile.url(forPhotoFolder: folder)
                    if FileManager.default.fileExists(atPath: poses.path) { try FileManager.default.removeItem(at: poses) }
                }
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                DispatchQueue.main.async { self.refresh() }
            } catch {
                DispatchQueue.main.async { self.warning = "Some recovery files could not be removed: \(error.localizedDescription)"; self.refresh() }
            }
        }
    }

    func refresh() {
        queue.async {
            var found: [CaptureDraft] = []
            var unreadable = 0
            do {
                if FileManager.default.fileExists(atPath: self.root.path) {
                    _ = try LibraryFileSafety.child("CaptureRecovery", of: self.documents)
                    let folders = try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)
                    for folder in folders {
                        guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                        do {
                            _ = try self.checkedDirectory(id)
                            let manifest = try self.store(id).readManifest()
                            guard manifest.id == id else { throw CocoaError(.fileReadCorruptFile) }
                            found.append(manifest)
                        } catch { unreadable += 1 }
                    }
                }
                DispatchQueue.main.async {
                    self.drafts = found.sorted { $0.checkpointAt > $1.checkpointAt }
                    if unreadable > 0 { self.warning = "\(unreadable) unreadable checkpoint(s) preserved on disk. They have not been deleted." }
                }
            } catch {
                DispatchQueue.main.async { self.warning = "Could not read unfinished captures: \(error.localizedDescription)" }
            }
        }
    }
}
