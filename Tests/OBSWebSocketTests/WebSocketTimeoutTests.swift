import Foundation
import Network
import Testing

@testable import OBSWebSocket

@MainActor
struct WebSocketTimeoutTests {
  @Test func aServerThatNeverAnswersTimesOut() async throws {
    let server = try await SilentServer.start()
    let socket = WebSocket()
    socket.connectionTimeout = 0.3

    socket.connect(host: "localhost", port: Int(server.port.rawValue))

    #expect(await socket.becomes(.Disconnected, within: 3))

    server.stop()
  }
}

/// Accepts TCP connections and never writes, so the WebSocket handshake cannot finish.
private final class SilentServer: @unchecked Sendable {
  let port: NWEndpoint.Port

  private let listener: NWListener
  private let connections: ConnectionHolder

  private init(listener: NWListener, port: NWEndpoint.Port, connections: ConnectionHolder) {
    self.listener = listener
    self.port = port
    self.connections = connections
  }

  static func start() async throws -> SilentServer {
    let listener = try NWListener(using: .tcp, on: .any)
    let connections = ConnectionHolder()

    listener.newConnectionHandler = { connection in
      connections.hold(connection)
      connection.start(queue: .global())
    }

    let port: NWEndpoint.Port = await withCheckedContinuation { continuation in
      listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port {
          listener.stateUpdateHandler = nil
          continuation.resume(returning: port)
        }
      }
      listener.start(queue: .global())
    }

    return SilentServer(listener: listener, port: port, connections: connections)
  }

  func stop() {
    listener.cancel()
    connections.cancelAll()
  }
}

private final class ConnectionHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [NWConnection] = []

  func hold(_ connection: NWConnection) {
    lock.lock()
    defer { lock.unlock() }
    connections.append(connection)
  }

  func cancelAll() {
    lock.lock()
    defer { lock.unlock() }
    for connection in connections {
      connection.cancel()
    }
    connections.removeAll()
  }
}
