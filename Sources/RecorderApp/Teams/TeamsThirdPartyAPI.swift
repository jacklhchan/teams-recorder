import Foundation

struct TeamsThirdPartyAPIIdentity: Equatable, Sendable {
    let manufacturer: String
    let device: String
    let app: String
    let appVersion: String

    static func recorder(appVersion: String) -> TeamsThirdPartyAPIIdentity {
        TeamsThirdPartyAPIIdentity(
            manufacturer: "Local Meeting Recorder",
            device: "macOS Audio Bridge",
            app: "Local Meeting Recorder",
            appVersion: appVersion
        )
    }
}

struct TeamsMeetingState: Equatable, Sendable {
    let isInMeeting: Bool
    let isMuted: Bool
    let canToggleMute: Bool
    let canPair: Bool
}

struct TeamsThirdPartyAPIMeetingUpdate: Equatable, Sendable {
    let state: TeamsMeetingState?
    let canToggleMute: Bool
    let canPair: Bool
}

enum TeamsThirdPartyAPIAction: String, Sendable {
    case pair
    case queryState = "query-state"
}

enum TeamsThirdPartyAPIEvent: Equatable, Sendable {
    case meetingUpdate(TeamsThirdPartyAPIMeetingUpdate)
    case tokenRefresh(String)
    case response(requestID: Int?, message: String)
    case error(requestID: Int?, message: String)
    case ignored
}

enum TeamsThirdPartyAPI {
    static let host = "127.0.0.1"
    static let port = 8124
    static let protocolVersion = "2.0.0"

    static func endpoint(
        token: String?,
        identity: TeamsThirdPartyAPIIdentity
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port

        var queryItems: [URLQueryItem] = []
        if let token, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "protocol-version", value: protocolVersion),
            URLQueryItem(name: "manufacturer", value: identity.manufacturer),
            URLQueryItem(name: "device", value: identity.device),
            URLQueryItem(name: "app", value: identity.app),
            URLQueryItem(name: "app-version", value: identity.appVersion)
        ])
        components.queryItems = queryItems
        return components.url
    }

    static func command(
        action: TeamsThirdPartyAPIAction,
        requestID: Int
    ) -> Data {
        let command = ClientCommand(
            action: action.rawValue,
            parameters: [:],
            requestID: requestID
        )
        return (try? JSONEncoder().encode(command)) ?? Data()
    }

    static func decode(_ text: String) throws -> TeamsThirdPartyAPIEvent {
        let message = try JSONDecoder().decode(
            ServerMessage.self,
            from: Data(text.utf8)
        )

        if let error = message.errorMsg, !error.isEmpty {
            return .error(requestID: message.requestID, message: error)
        }
        if let token = message.tokenRefresh, !token.isEmpty {
            return .tokenRefresh(token)
        }
        if let update = message.meetingUpdate {
            let canToggleMute = update.meetingPermissions?.canToggleMute ?? false
            let canPair = update.meetingPermissions?.canPair ?? false
            let state: TeamsMeetingState? = update.meetingState.flatMap {
                guard let isInMeeting = $0.isInMeeting,
                      let isMuted = $0.isMuted else {
                    return nil
                }
                return TeamsMeetingState(
                    isInMeeting: isInMeeting,
                    isMuted: isMuted,
                    canToggleMute: canToggleMute,
                    canPair: canPair
                )
            }
            return .meetingUpdate(
                TeamsThirdPartyAPIMeetingUpdate(
                    state: state,
                    canToggleMute: canToggleMute,
                    canPair: canPair
                )
            )
        }
        if let response = message.response, !response.isEmpty {
            return .response(
                requestID: message.requestID,
                message: response
            )
        }
        return .ignored
    }

    private struct ClientCommand: Encodable {
        let action: String
        let parameters: [String: String]
        let requestID: Int

        enum CodingKeys: String, CodingKey {
            case action
            case parameters
            case requestID = "requestId"
        }
    }

    private struct ServerMessage: Decodable {
        let requestID: Int?
        let response: String?
        let errorMsg: String?
        let tokenRefresh: String?
        let meetingUpdate: MeetingUpdate?

        enum CodingKeys: String, CodingKey {
            case requestID = "requestId"
            case response
            case errorMsg
            case tokenRefresh
            case meetingUpdate
        }
    }

    private struct MeetingUpdate: Decodable {
        let meetingState: MeetingState?
        let meetingPermissions: MeetingPermissions?
    }

    private struct MeetingState: Decodable {
        let isMuted: Bool?
        let isInMeeting: Bool?
    }

    private struct MeetingPermissions: Decodable {
        let canToggleMute: Bool?
        let canPair: Bool?
    }
}
