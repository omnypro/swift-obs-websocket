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
    let server = try await SilentServer.start()
    defer { server.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: Int(server.port.rawValue))
    socket.sendMessage("too early")

    #expect(socket.state == .startingUp)
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

  @Test func asksForTheRootPathWithTheHostAndPort() async throws {
    let recorder = try await RequestRecorder.start()
    defer { recorder.stop() }
    let socket = WebSocket()

    socket.connect(host: "localhost", port: recorder.portNumber)

    #expect(await eventually { recorder.request != nil })

    let request = try #require(recorder.request)
    let lines = request.components(separatedBy: "\r\n")

    #expect(lines.first == "GET / HTTP/1.1")
    #expect(
      lines.filter { $0.lowercased().hasPrefix("host:") } == [
        "Host: localhost:\(recorder.portNumber)"
      ])
    #expect(lines.contains { $0.lowercased() == "upgrade: websocket" })
  }

  @Test(arguments: [
    ("localhost", "localhost:4455"),
    ("192.168.1.5", "192.168.1.5:4455"),
    ("demi.example.net", "demi.example.net:4455"),
    ("  localhost ", "localhost:4455"),
    ("::1", "[::1]:4455"),
    ("[::1]", "[::1]:4455"),
  ])
  func writesTheHostHeader(host: String, expected: String) {
    #expect(WebSocket.makeAuthority(host: host, port: 4455) == expected)
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
