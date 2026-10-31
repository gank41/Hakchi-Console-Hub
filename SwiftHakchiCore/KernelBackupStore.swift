import Foundation

public enum KernelBackupStore {
    public static func isRecognizedImage(_ data: Data) -> Bool {
        // Structural recognition permits backups of custom kernels; stock evidence is separate.
        (try? LegacyAndroidBootImage(data: data)) != nil
    }
    public static func save(data: Data, profile: ConsoleProfile, root: URL) throws -> URL {
        guard !profile.deviceID.isEmpty, profile.systemCode != "unknown", isRecognizedImage(data) else {
            throw SyncPlanError.invalidInput("The recovery image format or device identity could not be verified.")
        }
        let directory = root.appendingPathComponent(profile.storageKey).appendingPathComponent("Kernel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("kernel_backup.img")
        try data.write(to: image, options: .atomic)
        let manifest = BackupManifest(profile: profile, sourcePaths: ["console original-kernel backup"], archiveFilename: "kernel_backup.img", data: data)
        try manifest.verify(archive: Data(contentsOf: image), for: profile)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return image
    }
}
