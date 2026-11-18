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
    NetworkCase(error: .posix(.ECONNRESET), failure: .connectionLost),
    NetworkCase(error: .posix(.EPIPE), failure: .connectionLost),
    // kDNSServiceErr_NoSuchRecord and kDNSServiceErr_NoSuchName
    NetworkCase(error: .dns(-65554), failure: .hostNotFound),
    NetworkCase(error: .dns(-65538), failure: .hostNotFound),
    // kDNSServiceErr_PolicyDenied, which macOS returns when local network access is off
    NetworkCase(error: .dns(-65570), failure: .localNetworkDenied),
  ])
  func mapsANetworkError(_ testCase: NetworkCase) {
    #expect(ConnectionFailure(networkError: testCase.error) == testCase.failure)
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

  @Test func aHostThatDoesNotResolveFails() async {
    let socket = WebSocket()

    socket.connect(host: "no-such-host.invalid", port: 4455)

    #expect(await socket.becomes(.disconnected, within: 10))
    #expect(socket.failure == .hostNotFound)
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
}
