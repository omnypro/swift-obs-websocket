import CryptoKit
import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "pro.omny.OBSWebSocket", category: "OBSWebSocket")

public enum OpCode {
  public static let identify = 1
  public static let request = 6
}

public enum RequestType {
  public static let getCurrentProgramScene = "GetCurrentProgramScene"
  public static let getSceneList = "GetSceneList"
  public static let getVersion = "GetVersion"
  public static let setCurrentProgramScene = "SetCurrentProgramScene"
  public static let setSceneSceneTransitionOverride = "SetSceneSceneTransitionOverride"
}

public enum EventType {
  public static let currentProgramSceneChanged = "CurrentProgramSceneChanged"
}

@MainActor @Observable
public class OBSWebSocket: WebSocket {
  public var rpcVersion: Int = 0

  public var versionMajor: Int = 0
  public var versionMinor: Int = 0
  public var versionPatch: Int = 0

  public var obsWebSocketVersion: String = ""

  public var authenticationSalt: String = ""
  public var authenticationChallenge: String = ""

  public var sceneList: [String] = []

  public var currentSceneName: String = ""

  @ObservationIgnored public var authenticationPassword: String = ""

  @ObservationIgnored private var requestId: Int = 0

  @ObservationIgnored private var isReadyForRequests: Bool = false

  @ObservationIgnored private var requestedRpcVersion: Int = 0

  private static let notReadyForRequestsMessage = "OBS WebSocket is not ready to receive requests."

  /// The newest protocol version this client speaks. OBS announces its own in `Hello`.
  public nonisolated static let supportedRpcVersion = 1

  /// The `Scenes` event category, the only one this client reads.
  nonisolated static let sceneEventSubscription = 1 << 2

  /// The `Identify` message for a server that announced `serverRpcVersion`.
  nonisolated static func identifyMessage(
    serverRpcVersion: Int, authentication: String?
  ) -> [String: Any] {
    var data: [String: Any] = [
      "rpcVersion": min(serverRpcVersion, supportedRpcVersion),
      "eventSubscriptions": sceneEventSubscription,
    ]

    if let authentication {
      data["authentication"] = authentication
    }

    return ["op": OpCode.identify, "d": data]
  }

  override public func handleMessage(_ message: String) {
    do {
      let json =
        try JSONSerialization.jsonObject(with: Data(message.utf8), options: []) as AnyObject?

      guard let d = json?["d"] as? [String: AnyObject] else { return }

      if d["requestType"] as? String == RequestType.getSceneList {
        OBSWebSocket.parseGetSceneListResponse(
          d, sceneList: &sceneList, currentSceneName: &currentSceneName)
      } else if d["eventType"] as? String == EventType.currentProgramSceneChanged {
        OBSWebSocket.parseCurrentProgramSceneChanged(d, currentSceneName: &currentSceneName)
      }

      if let rpcVersion = d["rpcVersion"] as? Int {
        self.rpcVersion = rpcVersion
        requestedRpcVersion = min(rpcVersion, OBSWebSocket.supportedRpcVersion)

        if d["authentication"] is [String: String] {
          OBSWebSocket.parseAuthentication(
            d, authenticationChallenge: &authenticationChallenge,
            authenticationSalt: &authenticationSalt)

          if !authenticationChallenge.isEmpty && !authenticationSalt.isEmpty {
            let authentication = OBSWebSocket.generateAuthenticationString(
              password: authenticationPassword, salt: authenticationSalt,
              challenge: authenticationChallenge)

            sendDictionary(
              OBSWebSocket.identifyMessage(
                serverRpcVersion: rpcVersion, authentication: authentication))
          }
        } else {
          sendDictionary(
            OBSWebSocket.identifyMessage(serverRpcVersion: rpcVersion, authentication: nil))
        }

        if d["obsWebSocketVersion"] is String {
          OBSWebSocket.parseVersion(
            d, versionMajor: &versionMajor, versionMinor: &versionMinor,
            versionPatch: &versionPatch)

          obsWebSocketVersion = "\(versionMajor).\(versionMinor).\(versionPatch)"
        }
      } else if let negotiatedRpcVersion = d["negotiatedRpcVersion"] as? Int {
        if negotiatedRpcVersion != requestedRpcVersion {
          disconnect()

          return
        }

        isReadyForRequests = true

        requestGetVersion()

        requestGetSceneList()
      }
    } catch {
      logger.error("Reading a message failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public nonisolated static func parseAuthentication(
    _ d: [String: AnyObject], authenticationChallenge: inout String,
    authenticationSalt: inout String
  ) {
    if let authentication = d["authentication"],
      let challenge = authentication["challenge"] as? String,
      let salt = authentication["salt"] as? String
    {
      authenticationChallenge = challenge
      authenticationSalt = salt
    }
  }

  public nonisolated static func parseCurrentProgramSceneChanged(
    _ d: [String: AnyObject], currentSceneName: inout String
  ) {
    if let eventData = d["eventData"],
      let sceneName = eventData["sceneName"] as? String
    {
      currentSceneName = sceneName
    }
  }

  public nonisolated static func parseGetSceneListResponse(
    _ d: [String: AnyObject], sceneList: inout [String], currentSceneName: inout String
  ) {
    if let responseData = d["responseData"],
      let scenes = responseData["scenes"] as? [AnyObject]
    {
      if let sceneName = responseData["currentProgramSceneName"] as? String {
        currentSceneName = sceneName
      }

      if !scenes.isEmpty {
        sceneList = scenes.compactMap { ($0 as? [String: Any])?["sceneName"] as? String }
      }
    }
  }

  public nonisolated static func parseVersion(
    _ d: [String: AnyObject], versionMajor: inout Int, versionMinor: inout Int,
    versionPatch: inout Int
  ) {
    guard let version = d["obsWebSocketVersion"] as? String else { return }

    let parts = version.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
      .map { Int($0.prefix(while: { $0.isASCII && $0.isNumber })) }

    guard let major = parts.first.flatMap({ $0 }) else { return }

    versionMajor = major
    versionMinor = parts.count > 1 ? (parts[1] ?? 0) : 0
    versionPatch = parts.count > 2 ? (parts[2] ?? 0) : 0
  }

  public nonisolated static func generateAuthenticationString(
    password: String, salt: String, challenge: String
  ) -> String {
    let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()

    return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
  }

  public func requestGetVersion() {
    if !isReadyForRequests {
      logger.debug("\(OBSWebSocket.notReadyForRequestsMessage)")

      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.getVersion,
      ],
    ])
  }

  public func requestGetSceneList() {
    if !isReadyForRequests {
      logger.debug("\(OBSWebSocket.notReadyForRequestsMessage)")

      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.getSceneList,
      ],
    ])
  }

  public func requestGetCurrentScene() {
    if !isReadyForRequests {
      logger.debug("\(OBSWebSocket.notReadyForRequestsMessage)")

      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.getCurrentProgramScene,
      ],
    ])
  }

  public func requestSetSceneTransitionOverride(_ sceneName: String, transitionName: String = "Cut")
  {
    if !isReadyForRequests {
      logger.debug("\(OBSWebSocket.notReadyForRequestsMessage)")

      return
    }

    if sceneName.isEmpty || !sceneList.contains(sceneName) {
      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.setSceneSceneTransitionOverride,
        "requestData": [
          "sceneName": sceneName,
          "transitionName": transitionName,
        ],
      ],
    ])
  }

  public func requestSetCurrentScene(_ sceneName: String) {
    if !isReadyForRequests {
      logger.debug("\(OBSWebSocket.notReadyForRequestsMessage)")

      return
    }

    if sceneName.isEmpty || !sceneList.contains(sceneName) {
      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.setCurrentProgramScene,
        "requestData": [
          "sceneName": sceneName
        ],
      ],
    ])
  }
}
