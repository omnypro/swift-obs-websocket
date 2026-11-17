import Foundation
import Testing

@testable import OBSWebSocket

@MainActor
struct WebSocketTransportTests {
  @Test func connectsToAWebSocketServer() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)

    #expect(await socket.becomes(.connected, within: 3))
  }

  @Test func receivesATextMessage() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = RecordingSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.send("hello")

    #expect(await eventually { socket.messages == ["hello"] })
  }

  @Test func keepsReceivingAfterTheFirstMessage() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = RecordingSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.send("one")
    server.send("two")
    server.send("three")

    #expect(await eventually { socket.messages == ["one", "two", "three"] })
  }

  @Test func sendsATextMessage() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))

    socket.sendMessage("ping")

    #expect(await eventually { server.receivedTexts == ["ping"] })
  }

  @Test func doesNotSendBeforeTheConnectionIsOpen() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    socket.sendMessage("too early")
    #expect(socket.state == .startingUp)

    #expect(await socket.becomes(.connected, within: 3))
    try await Task.sleep(for: .milliseconds(300))

    #expect(server.receivedTexts.isEmpty)
  }

  @Test func aLateFailureFromTheOldConnectionLeavesTheNewOneAlone() async throws {
    let first = try await WebSocketServer.start()
    defer { first.stop() }
    let second = try await WebSocketServer.start()
    defer { second.stop() }
    let socket = RedialOnEndSocket()

    socket.connect(host: "localhost", port: first.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { first.hasConnection })

    // A message past the size limit makes the first connection fail. Its failure arrives
    // after the socket has already moved to the second connection.
    socket.redialPort = second.portNumber
    first.send(String(repeating: "a", count: WebSocket.maximumMessageSize + 1024))

    #expect(await eventually { socket.ends >= 1 })
    #expect(await socket.becomes(.connected, within: 3))
    try await Task.sleep(for: .milliseconds(500))

    #expect(socket.state == .connected)
    #expect(socket.ends == 1)
  }

  @Test func endsWhenTheServerSendsACloseFrame() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.sendClose()

    #expect(await socket.becomes(.disconnected, within: 3))
  }

  @Test func endsWhenTheServerDropsTheConnection() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.dropConnection()

    #expect(await socket.becomes(.disconnected, within: 3))
  }

  @Test func tellsTheServerItIsClosingWhenTheClientDisconnects() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))

    socket.disconnect()

    #expect(socket.state == .disconnected)
    #expect(await eventually { server.receivedCloseFrames == 1 })
  }

  @Test func reconnectsAfterTheServerDropsTheConnection() async throws {
    let server = try await WebSocketServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: server.portNumber)
    #expect(await socket.becomes(.connected, within: 3))
    #expect(await eventually { server.hasConnection })

    server.dropConnection()
    #expect(await socket.becomes(.disconnected, within: 3))

    socket.connect(host: "localhost", port: server.portNumber)

    #expect(await socket.becomes(.connected, within: 3))
  }

  @Test func asksForTheRootPathWithOneHostHeader() async throws {
    let recorder = try await RequestRecorder.start()
    defer { recorder.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: recorder.portNumber)

    #expect(await eventually { recorder.request != nil })

    let request = try #require(recorder.request)
    let lines = request.components(separatedBy: "\r\n")

    #expect(lines.first == "GET / HTTP/1.1")
    #expect(lines.filter { $0.lowercased().hasPrefix("host:") }.count == 1)
    #expect(lines.contains { $0.lowercased() == "upgrade: websocket" })
  }
}

/// Ends its connection and, if told to, dials a second one before the first one has finished
/// reporting.
@MainActor
final class RedialOnEndSocket: WebSocket {
  var redialPort: Int?
  var ends = 0

  override func disconnect() {
    let wasLive = state == .connected || state == .startingUp

    super.disconnect()

    guard wasLive else { return }

    ends += 1

    if let port = redialPort {
      redialPort = nil
      connect(host: "localhost", port: port)
    }
  }
}

@MainActor
final class RecordingSocket: WebSocket {
  private(set) var messages: [String] = []

  override func handleMessage(_ message: String) {
    messages.append(message)
  }
}

/// Polls until `condition` holds, because the network reports on its own schedule.
@MainActor
func eventually(within seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)

  while Date() < deadline {
    if condition() { return true }

    try? await Task.sleep(for: .milliseconds(20))
  }

  return condition()
}
