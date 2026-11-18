import Foundation
import Network

/// A WebSocket server that records what one client sends and can close or drop that client.
final class WebSocketServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "WebSocketServer")
  private let lock = NSLock()
  private var connection: NWConnection?
  private var texts: [String] = []
  private var closeFrames = 0
  private var port: NWEndpoint.Port = .any

  var portNumber: Int { lock.withLock { Int(port.rawValue) } }
  var hasConnection: Bool { lock.withLock { connection != nil } }
  var receivedTexts: [String] { lock.withLock { texts } }
  var receivedCloseFrames: Int { lock.withLock { closeFrames } }

  private init(listener: NWListener) {
    self.listener = listener
  }

  static func start() async throws -> WebSocketServer {
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(
      NWProtocolWebSocket.Options(), at: 0)

    let listener = try NWListener(using: parameters, on: .any)
    let server = WebSocketServer(listener: listener)

    listener.newConnectionHandler = { [weak server] connection in
      server?.accept(connection)
    }

    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil

          if let port = listener.port {
            continuation.resume(returning: port)
          } else {
            continuation.resume(throwing: NWError.posix(.EINVAL))
          }

        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)

        default:
          break
        }
      }
      listener.start(queue: server.queue)
    }

    server.lock.withLock { server.port = port }

    return server
  }

  func send(_ text: String) {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)

    transmit(Data(text.utf8), identifier: "text", metadata: metadata)
  }

  func sendClose(code: UInt16? = nil) {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)

    if let code {
      metadata.closeCode = .applicationCode(code)
    } else {
      metadata.closeCode = .protocolCode(.normalClosure)
    }

    transmit(nil, identifier: "close", metadata: metadata)
  }

  /// Sends a close frame with an OBS code and drops the TCP connection the moment it is written.
  /// A proxy, or a server that does not wait for the client's reply, tears down this way.
  func sendCloseThenDrop(code: UInt16) {
    guard let connection = lock.withLock({ connection }) else { return }

    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
    metadata.closeCode = .applicationCode(code)

    connection.send(
      content: nil,
      contentContext: NWConnection.ContentContext(identifier: "close", metadata: [metadata]),
      isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
  }

  /// Closes the TCP connection without a WebSocket close frame.
  func dropConnection() {
    lock.withLock { connection }?.cancel()
  }

  func stop() {
    listener.cancel()
    lock.withLock { connection }?.cancel()
  }

  private func transmit(_ data: Data?, identifier: String, metadata: NWProtocolWebSocket.Metadata) {
    guard let connection = lock.withLock({ connection }) else { return }

    connection.send(
      content: data,
      contentContext: NWConnection.ContentContext(identifier: identifier, metadata: [metadata]),
      isComplete: true, completion: .idempotent)
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock { self.connection = connection }

    connection.start(queue: queue)

    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self, error == nil else { return }

      let metadata =
        context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
        as? NWProtocolWebSocket.Metadata

      switch metadata?.opcode {
      case .text:
        if let data, let text = String(data: data, encoding: .utf8) {
          lock.withLock { texts.append(text) }
        }

      case .close:
        lock.withLock { closeFrames += 1 }
        return

      default:
        break
      }

      receive(on: connection)
    }
  }
}

/// Accepts one TCP connection, keeps the first bytes it receives, and never answers.
final class RequestRecorder: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "RequestRecorder")
  private let lock = NSLock()
  private var connection: NWConnection?
  private var received: String?
  private var port: NWEndpoint.Port = .any

  var portNumber: Int { lock.withLock { Int(port.rawValue) } }
  var request: String? { lock.withLock { received } }

  private init(listener: NWListener) {
    self.listener = listener
  }

  static func start() async throws -> RequestRecorder {
    let listener = try NWListener(using: .tcp, on: .any)
    let recorder = RequestRecorder(listener: listener)

    listener.newConnectionHandler = { [weak recorder] connection in
      recorder?.accept(connection)
    }

    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil

          if let port = listener.port {
            continuation.resume(returning: port)
          } else {
            continuation.resume(throwing: NWError.posix(.EINVAL))
          }

        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)

        default:
          break
        }
      }
      listener.start(queue: recorder.queue)
    }

    recorder.lock.withLock { recorder.port = port }

    return recorder
  }

  func stop() {
    listener.cancel()
    lock.withLock { connection }?.cancel()
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock { self.connection = connection }

    connection.start(queue: queue)

    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, _, _ in
      guard let self, let data else { return }

      lock.withLock { received = String(decoding: data, as: UTF8.self) }
    }
  }
}
