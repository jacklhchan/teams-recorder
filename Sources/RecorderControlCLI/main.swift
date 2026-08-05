import Darwin
import Dispatch
import Foundation
import RecorderControl

func writeLine(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

signal(SIGINT, SIG_IGN)
let task = Task {
    await RecorderCLIEntrypoint.run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        writeLine: writeLine
    ) {
        let executablePath = try RecorderCLIExecutablePath.current()
        let launcher = try RecorderAppLauncher(executablePath: executablePath)
        let endpoint = try RecorderControlEndpoint(bundleIdentifier: launcher.bundleIdentifier)
        return RecorderCLIApplication(
            client: RecorderCLISocketClient(socketPath: endpoint.socketPath),
            launcher: launcher,
            clock: SystemRecorderCLIClock(),
            writeLine: writeLine
        )
    }
}
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT)
interruptSource.setEventHandler {
    task.cancel()
}
interruptSource.resume()
let exitCode = await task.value
interruptSource.cancel()

exit(exitCode)
