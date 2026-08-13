import Foundation
import RecorderControl

func fail(_ error: ReleaseManifestError) -> Never { FileHandle.standardError.write(Data("release_manifest_error=\(error.rawValue)\n".utf8)); exit(Int32(error.rawValue)) }
func argument(_ name: String, in values: [String]) throws -> String { guard let index = values.firstIndex(of: name), index + 1 < values.count else { throw ReleaseManifestError.malformed }; return values[index + 1] }
func safeFile(_ path: String) throws -> URL { let url = URL(fileURLWithPath: path); var value: ObjCBool = false; guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &value), !value.boolValue, (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ReleaseManifestError.unsafeFile }; return url }
do {
    let values = Array(CommandLine.arguments.dropFirst()); guard let command = values.first else { throw ReleaseManifestError.malformed }
    if command == "verify" {
        let manifestURL = try safeFile(try argument("--manifest", in: values)); let signatureURL = try safeFile(try argument("--signature", in: values)); let zipURL = try safeFile(try argument("--zip", in: values)); let keyringURL = try safeFile(try argument("--keyring", in: values)); let floor = try argument("--minimum-build", in: values)
        let ring = try JSONDecoder().decode(ReleaseManifestKeyring.self, from: Data(contentsOf: keyringURL))
        try ReleaseManifest.verify(manifestData: Data(contentsOf: manifestURL), signature: Data(base64Encoded: String(decoding: Data(contentsOf: signatureURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? { throw ReleaseManifestError.malformed }(), zipData: Data(contentsOf: zipURL), keyring: ring, minimumBuild: floor)
        print("release_manifest_verified")
    } else { throw ReleaseManifestError.malformed }
} catch let error as ReleaseManifestError { fail(error) } catch { fail(.execution) }
