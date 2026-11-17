import Foundation
import Testing

@testable import OBSWebSocket

struct WebSocketURLTests {
  @Test(
    arguments: [
      ("localhost", "ws://localhost:4455"),
      ("192.168.1.5", "ws://192.168.1.5:4455"),
      ("demi.example.net", "ws://demi.example.net:4455"),
      ("  localhost ", "ws://localhost:4455"),
      ("::1", "ws://[::1]:4455"),
      ("[::1]", "ws://[::1]:4455"),
    ])
  func buildsAWebSocketURL(host: String, expected: String) {
    #expect(WebSocket.makeURL(host: host, port: 4455)?.absoluteString == expected)
  }

  @Test(arguments: ["", " ", "bad host", "my host.local"])
  func refusesAHostThatIsNotAURL(host: String) {
    #expect(WebSocket.makeURL(host: host, port: 4455) == nil)
  }
}
