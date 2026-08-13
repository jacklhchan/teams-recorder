import Darwin
import Foundation

guard CommandLine.arguments.count == 2 else { exit(64) }
let path = CommandLine.arguments[1]
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8) + [0]
guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(65) }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
let length = socklen_t(MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path) + bytes.count)
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(66) }
defer { close(fd) }
let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, length)
    }
}
guard result == 0 else { exit(67) }
guard write(fd, Array("ping".utf8), 4) == 4 else { exit(68) }
var reply = [UInt8](repeating: 0, count: 4)
guard read(fd, &reply, reply.count) == 4, reply == Array("pong".utf8) else { exit(69) }
