import Foundation

/// Resolves every supported Atmos master representation through one path.
/// A directory may be either a DAMF directory or a package root containing
/// DAMF/ADM/IAB representations. When several representations are present,
/// the unique DAMF manifest is preferred because it retains the native object
/// PCM and metadata files used by the DTS:X fixture qualification path.
public enum AtmosInputReader {
    public static func read(url: URL) throws -> AtmosMaster {
        let resolved = try resolve(url: url)
        switch resolved.pathExtension.lowercased() {
        case "atmos": return try AtmosMasterReader.read(manifestURL: resolved)
        case "wav": return try ADMBWFReader.read(url: resolved)
        case "mxf": return try IMFIABReader.read(url: resolved).master
        default:
            throw DTSError.unsupported("resolved Atmos input has an unsupported file type: \(resolved.path)")
        }
    }

    public static func resolve(url: URL) throws -> URL {
        let input = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            throw DTSError.io("Atmos input does not exist: \(input.path)")
        }
        guard isDirectory.boolValue else {
            switch input.pathExtension.lowercased() {
            case "atmos", "wav", "mxf": return input
            default:
                throw DTSError.unsupported("Atmos input must be DAMF .atmos, ADM BWF .wav, IMF IAB .mxf, or a directory containing one")
            }
        }

        let files = try descendantFiles(in: input)
        let manifests = files.filter { $0.pathExtension.lowercased() == "atmos" }
        if manifests.count == 1 { return manifests[0] }
        if manifests.count > 1 {
            throw DTSError.invalidArgument(
                "Atmos directory contains multiple DAMF manifests; select one explicitly: \(manifests.map(\.path).joined(separator: ", "))"
            )
        }

        let admCandidates = files.filter { $0.pathExtension.lowercased() == "wav" }
        if admCandidates.count == 1 { return admCandidates[0] }
        let iabCandidates = files.filter { $0.pathExtension.lowercased() == "mxf" }
        if iabCandidates.count == 1 { return iabCandidates[0] }
        throw DTSError.invalidArgument(
            "Atmos directory must contain one DAMF manifest, or exactly one ADM BWF/IAB file"
        )
    }

    private static func descendantFiles(in root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw DTSError.io("cannot enumerate Atmos directory: \(root.path)")
        }
        var files: [URL] = []
        for case let candidate as URL in enumerator {
            let values: URLResourceValues
            do { values = try candidate.resourceValues(forKeys: Set(keys)) }
            catch { throw DTSError.io("cannot inspect Atmos input \(candidate.path): \(error.localizedDescription)") }
            if values.isRegularFile == true, values.isSymbolicLink != true {
                files.append(candidate.standardizedFileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
