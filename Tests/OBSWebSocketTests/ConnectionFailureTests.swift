import Foundation
import Network
import Testing

@testable import OBSWebSocket

struct ConnectionFailureMappingTests {
  struct NetworkCase: Sendable {
    let error: NWError
    let failure: ConnectionFailure
  }

  @Test(arguments: [
    NetworkCase(error: .posix(.ECONNREFUSED), failure: .refused),
    NetworkCase(error: .posix(.ETIMEDOUT), failure: .timedOut),
    NetworkCase(error: .posix(.EHOSTUNREACH), failure: .timedOut),
    NetworkCase(error: .posix(.ENETUNREACH), failure: .timedOut),
    NetworkCase(error: .posix(.EHOSTDOWN), failure: .timedOut),
    // Before the socket opens, a reset or any other error means the peer is not OBS.
    NetworkCase(error: .posix(.ECONNRESET), failure: .refused),
    NetworkCase(error: .posix(.EPIPE), failure: .refused),
    NetworkCase(error: .posix(.ECONNABORTED), failure: .refused),
    NetworkCase(error: .posix(.EPROTO), failure: .refused),
    NetworkCase(error: .posix(.ENOTCONN), failure: .refused),
    NetworkCase(error: .tls(-9806), failure: .refused),
    // kDNSServiceErr_NoSuchRecord and kDNSServiceErr_NoSuchName
    NetworkCase(error: .dns(-65554), failure: .hostNotFound),
    NetworkCase(error: .dns(-65538), failure: .hostNotFound),
    // kDNSServiceErr_PolicyDenied, which macOS returns when local network access is off
    NetworkCase(error: .dns(-65570), failure: .localNetworkDenied),
  ])
  func mapsANetworkError(_ testCase: NetworkCase) {
    #expect(ConnectionFailure(networkError: testCase.error) == testCase.failure)
  }

  /// For a TCP connection macOS reports the local network block on the path, and the error is an
  /// ordinary POSIX code.
  @Test func aDeniedLocalNetworkPathWinsOverThePOSIXError() {
    #expect(
      ConnectionFailure(networkError: .posix(.EHOSTUNREACH), pathReason: .localNetworkDenied)
        == .localNetworkDenied)
  }

  @Test func aPathWithAnotherReasonFallsBackToTheError() {
    #expect(
      ConnectionFailure(networkError: .posix(.ECONNREFUSED), pathReason: .notAvailable)
        == .refused)
    #expect(
      ConnectionFailure(networkError: .posix(.ECONNREFUSED), pathReason: nil) == .refused)
  }

  struct CloseCase: Sendable {
    let code: Int
    let failure: ConnectionFailure
  }

  @Test(arguments: [
    CloseCase(code: 4009, failure: .authenticationFailed),
    CloseCase(code: 4010, failure: .unsupportedVersion),
    CloseCase(code: 4011, failure: .connectionLost),
    CloseCase(code: 4000, failure: .closedByOBS),
    CloseCase(code: 4002, failure: .closedByOBS),
    CloseCase(code: 4003, failure: .closedByOBS),
    CloseCase(code: 4004, failure: .closedByOBS),
    CloseCase(code: 4005, failure: .closedByOBS),
    CloseCase(code: 4006, failure: .closedByOBS),
    CloseCase(code: 4007, failure: .closedByOBS),
    CloseCase(code: 4008, failure: .closedByOBS),
    CloseCase(code: 4012, failure: .closedByOBS),
    CloseCase(code: 1000, failure: .connectionLost),
    CloseCase(code: 1001, failure: .connectionLost),
    CloseCase(code: 1006, failure: .connectionLost),
    CloseCase(code: 4999, failure: .closedByOBS),
  ])
  func mapsACloseCode(_ testCase: CloseCase) {
    #expect(ConnectionFailure(closeCode: testCase.code) == testCase.failure)
  }
}

@MainActor
struct ConnectionFailureTests {
  private let helloWithPassword =
    #"{"op":0,"d":{"obsStudioVersion":"32.0.0","obsWebSocketVersion":"5.7.0","rpcVersion":1,"authentication":{"challenge":"c","salt":"s"}}}"#
  private let helloWithoutPassword =
    #"{"op":0,"d":{"obsStudioVersion":"32.0.0","obsWebSocketVersion":"5.7.0","rpcVersion":1}}"#

  @Test func startsWithNoFailureAndNotReady() {
    let socket = OBSWebSocket()

    #expect(socket.failure == nil)
    #expect(!socket.isReady)
  }

  @Test func anInvalidAddressFails() {
    let socket = WebSocket()

    socket.connect(host: "bad host", port: 4455)

    #expect(socket.state == .disconnected)
    #expect(socket.failure == .invalidAddress)
  }

  @Test func aPortOutOfRangeFails() {
    let socket = WebSocket()

    socket.connect(host: "localhost", port: 70000)

    #expect(socket.failure == .invalidAddress)
  }

  @Test func aRefusedConnectionFails() async {
    let socket = WebSocket()

    socket.connect(host: "localhost", port: 1)

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .refused)
  }

  @Test func aServerThatNeverAnswersTimesOut() async throws {
    let server = try await SilentServer.start()
    let socket = WebSocket()
    socket.connectionTimeout = 0.3

    socket.connect(host: "localhost", port: Int(server.port.rawValue))

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .timedOut)

    server.stop()
  }

  @Test func aServerThatOpensTheSocketAndNeverSaysHelloTimesOut() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()
    socket.connectionTimeout = 0.3

    socket.connect(host: "localhost", port: server.portNumber)

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .timedOut)
    #expect(!socket.isReady)
  }

  @Test(arguments: [
    (UInt16(4009), ConnectionFailure.authenticationFailed),
    (UInt16(4010), ConnectionFailure.unsupportedVersion),
    (UInt16(4011), ConnectionFailure.connectionLost),
    (UInt16(4005), ConnectionFailure.closedByOBS),
  ])
  func aCloseFrameWithACodeFails(code: UInt16, failure: ConnectionFailure) async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.sendClose(code: code)

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == failure)
  }

  @Test func aDroppedConnectionIsALostConnection() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.dropConnection()

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .connectionLost)
  }

  @Test func aPasswordRequestWithNoPasswordFailsWithoutSendingALogin() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()
    socket.authenticationPassword = ""

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.send(helloWithPassword)

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .authenticationRequired)
    #expect(server.receivedTexts.isEmpty)
  }

  @Test func aPasswordRequestWithAPasswordSendsALogin() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()
    socket.authenticationPassword = "secret"

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.send(helloWithPassword)

    #expect(await eventually { server.receivedTexts.count == 1 })
    #expect(socket.failure == nil)
  }

  @Test func aServerWithoutAPasswordNeedsNoPassword() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()
    socket.authenticationPassword = ""

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.send(helloWithoutPassword)

    #expect(await eventually { server.receivedTexts.count == 1 })
    #expect(socket.failure == nil)
  }

  @Test func aVersionTheServerWillNotGrantFails() {
    let socket = OBSWebSocket()
    socket.state = .connected

    socket.handleMessage(helloWithoutPassword)
    socket.handleMessage(#"{"op":2,"d":{"negotiatedRpcVersion":2}}"#)

    #expect(socket.state == .disconnected)
    #expect(socket.failure == .unsupportedVersion)
    #expect(!socket.isReady)
  }

  @Test func aGrantedVersionMakesTheSocketReadyAndClearsTheFailure() async {
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: 1)
    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .refused)

    socket.state = .connected
    socket.handleMessage(helloWithoutPassword)
    socket.handleMessage(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)

    #expect(socket.isReady)
    #expect(socket.failure == nil)
  }

  @Test func aNewAttemptKeepsTheLastFailureUntilItSucceeds() async throws {
    let server = try await SilentServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()
    socket.connectionTimeout = 30

    socket.connect(host: "localhost", port: 1)
    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .refused)

    socket.connect(host: "localhost", port: Int(server.port.rawValue))

    #expect(socket.state == .startingUp)
    #expect(socket.failure == .refused)
  }

  @Test func disconnectingByHandClearsTheFailureAndReadiness() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: 1)
    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .refused)

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })
    server.send(helloWithoutPassword)
    #expect(await eventually { server.receivedTexts.count == 1 })
    server.send(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)
    #expect(await eventually { socket.isReady })

    socket.disconnect()

    #expect(socket.state == .disconnected)
    #expect(socket.failure == nil)
    #expect(!socket.isReady)
  }

  @Test func aDroppedConnectionResetsReadiness() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })
    server.send(helloWithoutPassword)
    #expect(await eventually { server.receivedTexts.count == 1 })
    server.send(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)
    #expect(await eventually { socket.isReady })

    server.dropConnection()

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(!socket.isReady)
    #expect(socket.failure == .connectionLost)
  }

  /// The close frame and the TCP close can reach the client together. The code must survive.
  @Test func aCloseFrameFollowedByAnImmediateDropKeepsItsCode() async throws {
    for _ in 0..<20 {
      let server = try await WebSocketServer.start()
      let socket = OBSWebSocket()
      socket.authenticationPassword = "secret"

      socket.connect(host: "localhost", port: server.portNumber)
      #expect(await socket.becomes(.connected, within: 3))
      #expect(await eventually { server.hasConnection })

      // Bytes the server never reads make its teardown abrupt.
      socket.sendMessage("unread")
      server.sendCloseThenDrop(code: 4009)

      #expect(await socket.becomes(.disconnected, within: 3))
      #expect(socket.failure == .authenticationFailed)

      server.stop()
    }
  }

  @Test func aPlainSocketClearsAnOldFailureWhenItConnects() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: 1)
    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .refused)

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))

    #expect(socket.failure == nil)
  }

  @Test func aReadySessionIsNotKilledByTheIdentifyTimer() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()
    socket.connectionTimeout = 0.3

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })
    server.send(helloWithoutPassword)
    #expect(await eventually { server.receivedTexts.count == 1 })
    server.send(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)
    #expect(await eventually { socket.isReady })

    try await Task.sleep(for: .milliseconds(700))

    #expect(socket.state == .connected)
    #expect(socket.isReady)
    #expect(socket.failure == nil)
  }

  @Test func theIdentifyTimerOfAnOldConnectionLeavesANewOneAlone() async throws {
    let first = try await WebSocketServer.start()
    defer { first.stop() }
    let second = try await WebSocketServer.start()
    defer { second.stop() }
    let socket = OBSWebSocket()
    socket.connectionTimeout = 0.6

    socket.connect(host: "localhost", port: first.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    try await Task.sleep(for: .milliseconds(250))

    socket.connect(host: "localhost", port: second.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { second.hasConnection })
    second.send(helloWithoutPassword)
    #expect(await eventually { second.receivedTexts.count == 1 })
    second.send(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)
    #expect(await eventually { socket.isReady })

    // The first connection's timer would fire about 0.35 s after the redial.
    try await Task.sleep(for: .milliseconds(700))

    #expect(socket.state == .connected)
    #expect(socket.isReady)
    #expect(socket.failure == nil)
  }

  // MARK: - Close frames that arrive with a socket error

  private func closeContext(code: UInt16) -> NWConnection.ContentContext {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
    metadata.closeCode = .applicationCode(code)

    return NWConnection.ContentContext(identifier: "close", metadata: [metadata])
  }

  /// Network.framework can hand over a close frame and an error in one completion.
  @Test func aCloseFrameDeliveredWithAnErrorKeepsItsCode() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    let connection = try #require(socket.connection)

    socket.received(
      nil, context: closeContext(code: 4009), error: .posix(.EPIPE), from: connection)

    #expect(socket.state == .disconnected)
    #expect(socket.failure == .authenticationFailed)
  }

  /// The failed state can arrive before the receive that holds the close frame.
  @Test func aCloseFrameJustAfterAFailedStateKeepsItsCode() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    let connection = try #require(socket.connection)

    socket.connectionStateChanged(.failed(.posix(.ENOTCONN)), of: connection)
    socket.received(nil, context: closeContext(code: 4009), error: nil, from: connection)

    #expect(socket.failure == .authenticationFailed)
  }

  @Test func aFailedStateWithNoCloseFrameIsALostConnectionAfterTheGrace() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    let connection = try #require(socket.connection)

    socket.connectionStateChanged(.failed(.posix(.ENOTCONN)), of: connection)

    #expect(await socket.becomes(.disconnected, within: 2))
    #expect(socket.failure == .connectionLost)
  }

  // MARK: - A peer that is not OBS

  /// Port 445 on a Mac with file sharing accepts the connection and resets it.
  @Test func aServerThatClosesAtOnceIsNotAcceptingConnections() async throws {
    let server = try await RawServer.start { $0.cancel() }
    defer { server.stop() }
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: server.portNumber)

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .refused)
  }

  @Test func aServerThatAnswersAsPlainHTTPIsNotAcceptingConnections() async throws {
    let server = try await RawServer.start { connection in
      connection.send(
        content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8),
        completion: .contentProcessed { _ in })
    }
    defer { server.stop() }
    let socket = OBSWebSocket()

    socket.connect(host: "localhost", port: server.portNumber)

    #expect(await socket.becomes(.disconnected, within: 3))
    #expect(socket.failure == .refused)
  }

  @Test func aConnectionCancelledBeforeItOpenedIsNotALostConnection() async throws {
    let server = try await SilentServer.start()
    defer { server.stop() }
    let socket = WebSocket()
    socket.connectionTimeout = 30

    socket.connect(host: "localhost", port: Int(server.port.rawValue))
    let connection = try #require(socket.connection)

    socket.connectionStateChanged(.cancelled, of: connection)

    #expect(socket.failure == .refused)
  }
}
