import Foundation
import Testing

@testable import OBSWebSocket

@MainActor
struct WebSocketConnectionTests {
  @Test func anInvalidHostEndsDisconnectedWithoutCrashing() {
    let socket = WebSocket()

    socket.connect(host: "bad host", port: 4455)

    #expect(socket.state == .disconnected)
  }

  @Test func aRefusedConnectionEndsDisconnected() async {
    let socket = WebSocket()

    socket.connect(host: "localhost", port: 1)

    #expect(await socket.becomes(.disconnected, within: 2))
  }
}

extension WebSocket {
  /// Polls until the socket reaches `target`, because the delegate reports on its own queue.
  @MainActor
  func becomes(_ target: WebSocketState, within seconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)

    while Date() < deadline {
      if state == target { return true }

      try? await Task.sleep(for: .milliseconds(20))
    }

    return state == target
  }
}
