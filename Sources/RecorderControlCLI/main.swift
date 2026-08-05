import Darwin
import Dispatch
import Foundation
import RecorderControl

func writeLine(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

let exitCode: Int32
do {
    let launcher = try RecorderAppLauncher(executablePath: CommandLine.arguments[0])
    let endpoint = try RecorderControlEndpoint(bundleIdentifier: launcher.bundleIdentifier)
    let application = RecorderCLIApplication(
        client: RecorderCLISocketClient(socketPath: endpoint.socketPath),
        launcher: launcher,
        clock: SystemRecorderCLIClock(),
        writeLine: writeLine
    )
    signal(SIGINT, SIG_IGN)
    let task = Task {
        await application.run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT)
    interruptSource.setEventHandler {
        task.cancel()
    }
    interruptSource.resume()
    exitCode = await task.value
    interruptSource.cancel()
} catch {
    writeLine("error: \(error.localizedDescription)")
    exitCode = 3
}

exit(exitCode)
