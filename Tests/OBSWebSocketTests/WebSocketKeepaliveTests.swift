import Network
import Testing

@testable import OBSWebSocket

struct WebSocketKeepaliveTests {
  private func tcpOptions() throws -> NWProtocolTCP.Options {
    let parameters = WebSocketConnectionParameters.make()

    return try #require(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
  }

  /// A peer that vanishes without closing leaves no packet to read. Keepalive probes turn the
  /// silence into a failed connection.
  @Test func probesAnIdleConnection() throws {
    let options = try tcpOptions()

    #expect(options.enableKeepalive)
    #expect(options.keepaliveIdle == 10)
    #expect(options.keepaliveInterval == 5)
    #expect(options.keepaliveCount == 3)
  }
}
