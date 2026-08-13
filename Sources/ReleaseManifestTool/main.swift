import Foundation
import RecorderControl

func fail(_ error: ReleaseManifestError) -> Never { FileHandle.standardError.write(Data("release_manifest_error=\(error.rawValue)\n".utf8)); exit(Int32(error.rawValue)) }
func parse(_ arguments: [String], names: Set<String>) throws -> [String: String] {
    var result: [String: String] = [:]; var index = 0
    while index < arguments.count { let name = arguments[index]; guard names.contains(name), index + 1 < arguments.count, result[name] == nil, !arguments[index + 1].hasPrefix("--") else { throw ReleaseManifestError.malformed }; result[name] = arguments[index + 1]; index += 2 }
    guard result.count == names.count else { throw ReleaseManifestError.malformed }; return result
}
func safeFile(_ path: String, writable: Bool = false) throws -> URL { let url = URL(fileURLWithPath: path); guard path.hasPrefix("/") else { throw ReleaseManifestError.unsafeFile }; if writable { guard !FileManager.default.fileExists(atPath: path) else { throw ReleaseManifestError.unsafeFile }; return url }; var directory: ObjCBool = false; guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue, (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ReleaseManifestError.unsafeFile }; return url }
do {
    let all = Array(CommandLine.arguments.dropFirst()); guard let command = all.first else { throw ReleaseManifestError.malformed }; let values = Array(all.dropFirst())
    if command == "verify" {
        let args = try parse(values, names: ["--manifest", "--signature", "--zip", "--keyring", "--minimum-build"])
        let manifest = try safeFile(args["--manifest"]!); let signature = try safeFile(args["--signature"]!); let zip = try safeFile(args["--zip"]!); let keyring = try safeFile(args["--keyring"]!)
        let text = String(decoding: try Data(contentsOf: signature), as: UTF8.self); guard text.hasSuffix("\n"), text.dropLast().range(of: "\\s", options: .regularExpression) == nil, let sig = Data(base64Encoded: String(text.dropLast())) else { throw ReleaseManifestError.malformed }
        try ReleaseManifest.verify(manifestData: Data(contentsOf: manifest), signature: sig, zipData: Data(contentsOf: zip), keyring: try JSONDecoder().decode(ReleaseManifestKeyring.self, from: Data(contentsOf: keyring)), minimumBuild: args["--minimum-build"]!); print("release_manifest_verified")
    } else if command == "sign" {
        let args = try parse(values, names: ["--manifest-out", "--signature-out", "--version", "--build", "--minimum-accepted-build", "--git-commit", "--provenance-id", "--zip", "--key-id", "--private-key-file"])
        let zip = try safeFile(args["--zip"]!); let key = try safeFile(args["--private-key-file"]!); let manifestOut = try safeFile(args["--manifest-out"]!, writable: true); let signatureOut = try safeFile(args["--signature-out"]!, writable: true)
        let seed = try Data(contentsOf: key); guard seed.count == 32, args["--git-commit"]!.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw ReleaseManifestError.malformed }
        let value = try ReleaseManifest(version: args["--version"]!, build: args["--build"]!, minimumAcceptedBuild: args["--minimum-accepted-build"]!, gitCommit: args["--git-commit"]!, keyID: args["--key-id"]!, provenanceID: args["--provenance-id"]!, zipFilename: zip.lastPathComponent, zipData: Data(contentsOf: zip)); let bytes = try value.canonicalData(); try bytes.write(to: manifestOut, options: .withoutOverwriting); try Data((try ReleaseManifest.sign(bytes, privateKeySeed: seed)).base64EncodedString().appending("\n").utf8).write(to: signatureOut, options: .withoutOverwriting)
    } else { throw ReleaseManifestError.malformed }
} catch let error as ReleaseManifestError { fail(error) } catch { fail(.execution) }
