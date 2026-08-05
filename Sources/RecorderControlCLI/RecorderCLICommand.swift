import RecorderControl

enum RecorderCLICommand: Equatable {
    case status(json: Bool)
    case watch(json: Bool)
    case request(RecorderControlCommand, String?)

    init(arguments: [String]) throws {
        switch arguments {
        case ["status"]:
            self = .status(json: false)
        case ["status", "--json"]:
            self = .status(json: true)
        case ["watch"]:
            self = .watch(json: false)
        case ["watch", "--json"]:
            self = .watch(json: true)
        case ["start"]:
            self = .request(.start, nil)
        case ["stop"]:
            self = .request(.stop, nil)
        case ["auto", "on"]:
            self = .request(.setAuto, "on")
        case ["auto", "off"]:
            self = .request(.setAuto, "off")
        case ["mic", "mute"]:
            self = .request(.setMic, "mute")
        case ["mic", "unmute"]:
            self = .request(.setMic, "unmute")
        default:
            throw RecorderCLIParseError.invalidArguments
        }
    }
}

private enum RecorderCLIParseError: Error {
    case invalidArguments
}
