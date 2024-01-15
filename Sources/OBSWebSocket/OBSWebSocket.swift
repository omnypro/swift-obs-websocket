import Crypto
import Foundation

public final class OpCode {
  public static var Identify: Int = 1
  public static var Request: Int = 6
}

public final class RequestType {
  public static var GetCurrentProgramScene: String = "GetCurrentProgramScene"
  public static var GetSceneList: String = "GetSceneList"
  public static var GetVersion: String = "GetVersion"
  public static var SetCurrentProgramScene: String = "SetCurrentProgramScene"
  public static var SetSceneSceneTransitionOverride: String = "SetSceneSceneTransitionOverride"
}

public final class EventType {
  public static var CurrentProgramSceneChanged: String = "CurrentProgramSceneChanged"
}

@available(macOS 10.15, *)
public class OBSWebSocket: WebSocket {
  @Published public var rpcVersion: Int = 0

  @Published public var versionMajor: Int = 0
  @Published public var versionMinor: Int = 0
  @Published public var versionPatch: Int = 0

  @Published public var obsWebSocketVersion: String = ""

  @Published public var authenticationSalt: String = ""
  @Published public var authenticationChallenge: String = ""

  @Published public var sceneList: [String] = []

  private var requestId: Int = 0

  public var authenticationPassword: String = ""

  public var currentSceneName: String = ""

  private var isReadyForRequests: Bool = false

  private var notReadyForRequestsMessage: String = "OBS WebSocket is not ready to receive requests."

  override public func handleMessage(_ message: String) {
    do {
      let data = message.data(using: .utf8)

      let json = try JSONSerialization.jsonObject(with: data!, options: []) as AnyObject?

      if let d = json?["d"] as? [String: AnyObject] {
        if d["requestType"] as? String == RequestType.GetSceneList {
          DispatchQueue.main.async { [self] in
            OBSWebSocket.parseGetSceneListResponse(
              d, sceneList: &sceneList, currentSceneName: &currentSceneName)
          }
        } else if d["eventType"] as? String == EventType.CurrentProgramSceneChanged {
          DispatchQueue.main.async { [self] in
            OBSWebSocket.parseCurrentProgramSceneChanged(d, currentSceneName: &currentSceneName)
          }
        }

        if let rpcVersion = d["rpcVersion"] as? Int {
          DispatchQueue.main.async { [self] in
            self.rpcVersion = rpcVersion
          }

          if d["authentication"] is [String: String] {
            DispatchQueue.main.async { [self] in
              OBSWebSocket.parseAuthentication(
                d, authenticationChallenge: &authenticationChallenge,
                authenticationSalt: &authenticationSalt)

              if !authenticationChallenge.isEmpty && !authenticationSalt.isEmpty {
                let authentication = OBSWebSocket.generateAuthenticationString(
                  password: authenticationPassword, salt: authenticationSalt,
                  challenge: authenticationChallenge)

                sendDictionary([
                  "op": OpCode.Identify,
                  "d": [
                    "rpcVersion": rpcVersion,
                    "authentication": authentication,
                  ],
                ])
              }
            }
          } else {
            sendDictionary([
              "op": OpCode.Identify,
              "d": [
                "rpcVersion": rpcVersion
              ],
            ])
          }

          if d["obsWebSocketVersion"] is String {
            DispatchQueue.main.async { [self] in
              OBSWebSocket.parseVersion(
                d, versionMajor: &versionMajor, versionMinor: &versionMinor,
                versionPatch: &versionPatch)

              obsWebSocketVersion = "\(versionMajor).\(versionMinor).\(versionPatch)"
            }
          }

        } else if let negotiatedRpcVersion = d["negotiatedRpcVersion"] as? Int {
          if negotiatedRpcVersion != rpcVersion {
            disconnect()

            return
          }

          isReadyForRequests = true

          requestGetVersion()

          requestGetSceneList()
        }
      }
    } catch {
      print(error.localizedDescription)
    }
  }

  public static func parseAuthentication(
    _ d: [String: AnyObject], authenticationChallenge: inout String,
    authenticationSalt: inout String
  ) {
    if let authentication = d["authentication"],
      let _authenticationChallenge = authentication["challenge"] as? String,
      let _authenticationSalt = authentication["salt"] as? String
    {
      authenticationChallenge = _authenticationChallenge
      authenticationSalt = _authenticationSalt
    }
  }

  public static func parseCurrentProgramSceneChanged(
    _ d: [String: AnyObject], currentSceneName: inout String
  ) {
    if let eventData = d["eventData"],
      let _currentSceneName = eventData["sceneName"] as? String
    {
      currentSceneName = _currentSceneName
    }
  }

  public static func parseGetSceneListResponse(
    _ d: [String: AnyObject], sceneList: inout [String], currentSceneName: inout String
  ) {
    if let responseData = d["responseData"],
      let _currentSceneName = responseData["currentProgramSceneName"] as? String,
      let scenes = responseData["scenes"] as? [AnyObject]
    {
      currentSceneName = _currentSceneName

      if scenes.count > 0 {
        sceneList.removeAll()

        for i in 0..<scenes.count {
          if let sceneName = scenes[i]["sceneName"] {
            sceneList.append(sceneName as! String)
          }
        }
      }
    }
  }

  public static func parseVersion(
    _ d: [String: AnyObject], versionMajor: inout Int, versionMinor: inout Int,
    versionPatch: inout Int
  ) {
    if let obsWebSocketVersion = d["obsWebSocketVersion"] as? String {
      do {
        let regex = try NSRegularExpression(
          pattern: "^(?:(\\d+))(?:\\.(\\d+))?(?:\\.(\\d+))?")

        let nsrange = NSRange(
          obsWebSocketVersion.startIndex..<obsWebSocketVersion.endIndex,
          in: obsWebSocketVersion
        )

        if let match = regex.firstMatch(in: obsWebSocketVersion, range: nsrange) {
          versionMajor = Int(
            (obsWebSocketVersion as NSString).substring(with: match.range(at: 1)))!
          versionMinor = Int(
            (obsWebSocketVersion as NSString).substring(with: match.range(at: 2)))!
          versionPatch = Int(
            (obsWebSocketVersion as NSString).substring(with: match.range(at: 3)))!
        }
      } catch {
        print(error.localizedDescription)
      }
    }
  }

  public static func generateAuthenticationString(password: String, salt: String, challenge: String)
    -> String
  {
    let base64_secret = Data(SHA256.hash(data: (password + salt).data(using: .utf8)!))
      .base64EncodedString()
    let authentication = Data(SHA256.hash(data: (base64_secret + challenge).data(using: .utf8)!))
      .base64EncodedString()

    return authentication
  }

  public func requestGetVersion() {
    if !isReadyForRequests {
      print(notReadyForRequestsMessage)

      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.Request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.GetVersion,
      ],
    ])
  }

  public func requestGetSceneList() {
    if !isReadyForRequests {
      print(notReadyForRequestsMessage)

      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.Request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.GetSceneList,
      ],
    ])
  }

  public func requestGetCurrentScene() {
    if !isReadyForRequests {
      print(notReadyForRequestsMessage)

      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.Request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.GetCurrentProgramScene,
      ],
    ])
  }

  public func requestSetSceneTransitionOverride(_ sceneName: String, transitionName: String = "Cut") {
    if !isReadyForRequests {
      print(notReadyForRequestsMessage)

      return
    }

    if sceneName.isEmpty || !sceneList.contains(sceneName) {
      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.Request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.SetSceneSceneTransitionOverride,
        "requestData": [
          "sceneName": sceneName,
          "transitionName": transitionName,
        ],
      ],
    ])
  }

  public func requestSetCurrentScene(_ sceneName: String) {
    if !isReadyForRequests {
      print(notReadyForRequestsMessage)

      return
    }

    if sceneName.isEmpty || !sceneList.contains(sceneName) {
      return
    }

    requestId += 1

    sendDictionary([
      "op": OpCode.Request,
      "d": [
        "requestId": String(requestId),
        "requestType": RequestType.SetCurrentProgramScene,
        "requestData": [
          "sceneName": sceneName
        ],
      ],
    ])
  }
}
