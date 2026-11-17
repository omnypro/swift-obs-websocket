import Testing

@testable import OBSWebSocket

@MainActor
struct OBSWebSocketHandshakeTests {
  private let hello2 =
    #"{"op":0,"d":{"obsStudioVersion":"32.0.0","obsWebSocketVersion":"5.7.0","rpcVersion":2}}"#
  private let hello1 =
    #"{"op":0,"d":{"obsStudioVersion":"32.0.0","obsWebSocketVersion":"5.7.0","rpcVersion":1}}"#

  @Test func asksForTheClosestVersionItSupports() {
    let message = OBSWebSocket.identifyMessage(serverRpcVersion: 2, authentication: nil)
    let data = message["d"] as? [String: Any]

    #expect(message["op"] as? Int == OpCode.identify)
    #expect(data?["rpcVersion"] as? Int == 1)
  }

  @Test func asksForTheServersVersionWhenItIsOlder() {
    let message = OBSWebSocket.identifyMessage(serverRpcVersion: 0, authentication: nil)
    let data = message["d"] as? [String: Any]

    #expect(data?["rpcVersion"] as? Int == 0)
  }

  @Test func subscribesOnlyToSceneEvents() {
    let message = OBSWebSocket.identifyMessage(serverRpcVersion: 1, authentication: nil)
    let data = message["d"] as? [String: Any]

    #expect(data?["eventSubscriptions"] as? Int == 1 << 2)
  }

  @Test func sendsTheAuthenticationStringOnlyWhenThereIsOne() {
    let without = OBSWebSocket.identifyMessage(serverRpcVersion: 1, authentication: nil)
    let with = OBSWebSocket.identifyMessage(serverRpcVersion: 1, authentication: "abc=")

    #expect((without["d"] as? [String: Any])?.keys.contains("authentication") == false)
    #expect((with["d"] as? [String: Any])?["authentication"] as? String == "abc=")
  }

  @Test func staysConnectedWhenTheServerGrantsTheVersionTheClientAskedFor() {
    let socket = OBSWebSocket()
    socket.state = .connected

    socket.handleMessage(hello2)
    socket.handleMessage(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)

    #expect(socket.state == .connected)
  }

  @Test func disconnectsWhenTheServerGrantsADifferentVersion() {
    let socket = OBSWebSocket()
    socket.state = .connected

    socket.handleMessage(hello1)
    socket.handleMessage(#"{"op":2,"d":{"negotiatedRpcVersion":2}}"#)

    #expect(socket.state == .disconnected)
  }
}
