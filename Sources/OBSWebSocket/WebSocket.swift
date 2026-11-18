import Foundation
import Network
import OSLog
import Observation

private let logger = Logger(subsystem: "pro.omny.OBSWebSocket", category: "WebSocket")

/// A WebSocket client whose state SwiftUI can observe.
///
/// The connection uses Network.framework. URLSession would hold a `ws://` connection to
/// App Transport Security, which blocks fully qualified host names that have no TLS.
/// OBS speaks plain `ws://`, so that block would stop a Mac from reaching OBS by name.
@MainActor @Observable
public class WebSocket {
  public var state: WebSocketState = .idle

  /// Why the last attempt or session ended. It stays until a session becomes ready or
  /// `disconnect()` clears it, so a client can keep showing it while it retries.
  public internal(set) var failure: ConnectionFailure?

  /// How long a connection may stay in `.startingUp` before it is given up.
  public var connectionTimeout: TimeInterval = 5

  /// The largest message the socket accepts, in bytes. OBS messages are far smaller.
  nonisolated static let maximumMessageSize = 8 * 1024 * 1024

  @ObservationIgnored var connection: NWConnection?
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?

  public init() {}

  /// The WebSocket URL for a host the user typed, or `nil` when the host and port do not form
  /// a URL that names exactly that host and port.
  nonisolated static func makeURL(host: String, port: Int) -> URL? {
    guard (1...65535).contains(port) else { return nil }

    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else { return nil }

    let isBareIPv6 = trimmed.contains(":") && !trimmed.hasPrefix("[")

    guard let url = URL(string: "ws://\(isBareIPv6 ? "[\(trimmed)]" : trimmed):\(port)"),
      let parsedHost = url.host(), url.port == port, url.path.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else { return nil }

    // Text with a colon is a host only when it is an IPv6 address.
    if parsedHost.contains(":"), IPv6Address(parsedHost) == nil { return nil }

    return url
  }

  public func connect(host: String = "localhost", port: Int = 4455) {
    endConnection()

    guard let url = WebSocket.makeURL(host: host, port: port) else {
      fail(.invalidAddress)
      return
    }

    let connection = NWConnection(to: .url(url), using: WebSocketConnectionParameters.make())

    self.connection = connection
    state = .startingUp

    // The main queue delivers every callback in order, so a message cannot overtake the
    // `.ready` that comes before it.
    connection.stateUpdateHandler = { [weak self, weak connection] newState in
      MainActor.assumeIsolated {
        guard let self, let connection else { return }

        self.connectionStateChanged(newState, of: connection)
      }
    }

    connection.start(queue: .main)

    timeoutTask = Task { [weak self, connectionTimeout] in
      try? await Task.sleep(for: .seconds(connectionTimeout))

      guard !Task.isCancelled else { return }

      self?.connectionTimedOut(connection)
    }
  }

  public func handleMessage(_ message: String) {
    logger.debug("Received a message: \(message, privacy: .private)")
  }

  public func sendMessage(_ message: String) {
    guard let connection, connection.state == .ready else { return }

    let context = NWConnection.ContentContext(
      identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])

    connection.send(
      content: Data(message.utf8), contentContext: context, isComplete: true,
      completion: .contentProcessed { error in
        if let error {
          logger.error("Sending failed: \(error.localizedDescription, privacy: .public)")
        }
      })
  }

  public func sendDictionary(_ dict: Any) {
    do {
      let data = try JSONSerialization.data(withJSONObject: dict)

      if let jsonString = String(data: data, encoding: .utf8) {
        sendMessage(jsonString)
      }
    } catch {
      logger.error("Encoding failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Ends the connection on the client's request. That is not a failure, so it clears one.
  public func disconnect() {
    failure = nil

    endConnection()
  }

  /// Called when the socket opens. A plain socket has nothing left to do, so an old failure ends
  /// here. A subclass with a handshake of its own starts it instead and clears the failure when
  /// the handshake succeeds.
  func connectionDidOpen() {
    failure = nil
  }

  /// Called when a connection that was starting or open has ended, however it ended.
  func connectionDidEnd() {}

  /// Records why the connection failed and ends it.
  func fail(_ reason: ConnectionFailure) {
    logger.error("The connection failed: \(String(describing: reason), privacy: .public)")

    failure = reason

    if state == .connected || state == .startingUp {
      endConnection()
    } else {
      state = .disconnected
    }
  }

  private func endConnection() {
    guard state == .connected || state == .startingUp else { return }

    state = .disconnected

    timeoutTask?.cancel()
    timeoutTask = nil

    if let connection {
      self.connection = nil
      WebSocket.close(connection)
    }

    connectionDidEnd()
  }

  isolated deinit {
    timeoutTask?.cancel()

    if let connection {
      WebSocket.close(connection)
    }
  }

  /// Ends a connection the socket no longer tracks. A connection that finished its
  /// handshake gets a close frame first.
  private static func close(_ connection: NWConnection) {
    connection.stateUpdateHandler = nil

    guard connection.state == .ready else {
      connection.cancel()
      return
    }

    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
    metadata.closeCode = .protocolCode(.normalClosure)

    connection.send(
      content: nil,
      contentContext: NWConnection.ContentContext(identifier: "close", metadata: [metadata]),
      isComplete: true, completion: .contentProcessed { _ in connection.cancel() })

    // A peer that has stopped reading never completes the send, so cancel after a moment.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { connection.cancel() }
  }

  func connectionStateChanged(_ newState: NWConnection.State, of connection: NWConnection) {
    guard connection === self.connection else { return }

    switch newState {
    case .ready:
      state = .connected

      timeoutTask?.cancel()

      connectionDidOpen()

      receiveMessage(from: connection)

    case .waiting(let error), .failed(let error):
      // `.waiting` is where a refused connection or a failed lookup lands, and the
      // connection would retry it for as long as it lives.
      logger.error("Connecting failed: \(error.localizedDescription, privacy: .public)")

      if state == .connected {
        // An error on an open connection is a drop, but a close frame with a reason may still
        // be on its way. The receive that holds it gets a moment to report first.
        failAfterGrace(.connectionLost, on: connection)
      } else {
        fail(
          ConnectionFailure(
            networkError: error, pathReason: connection.currentPath?.unsatisfiedReason))
      }

    case .cancelled:
      if state == .connected {
        failAfterGrace(.connectionLost, on: connection)
      } else {
        fail(.connectionLost)
      }

    default:
      break
    }
  }

  private func receiveMessage(from connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] data, context, _, error in
      MainActor.assumeIsolated {
        guard let self, let connection else { return }

        self.received(data, context: context, error: error, from: connection)
      }
    }
  }

  func received(
    _ data: Data?, context: NWConnection.ContentContext?, error: NWError?,
    from connection: NWConnection
  ) {
    guard connection === self.connection else { return }

    let metadata =
      context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
      as? NWProtocolWebSocket.Metadata

    // A close frame can arrive in the same completion as an error, and its code is the reason.
    if metadata?.opcode == .close {
      fail(ConnectionFailure(closeCode: WebSocket.code(of: metadata?.closeCode)))
      return
    }

    if let error {
      logger.error("Receiving failed: \(error.localizedDescription, privacy: .public)")

      fail(.connectionLost)
      return
    }

    switch metadata?.opcode {
    case .text:
      if let data, let text = String(data: data, encoding: .utf8) {
        handleMessage(text)
      }

      receiveMessage(from: connection)

    default:
      receiveMessage(from: connection)
    }
  }

  /// Reports `reason` after a moment, unless a receive has already ended this connection with a
  /// better one.
  private func failAfterGrace(_ reason: ConnectionFailure, on connection: NWConnection) {
    Task {
      try? await Task.sleep(for: .milliseconds(100))

      guard connection === self.connection else { return }

      fail(reason)
    }
  }

  private func connectionTimedOut(_ connection: NWConnection) {
    guard connection === self.connection, state == .startingUp else { return }

    fail(.timedOut)
  }

  /// The number in a close frame, or 1005 when the frame carries none.
  private static func code(of closeCode: NWProtocolWebSocket.CloseCode?) -> Int {
    switch closeCode {
    case .protocolCode(let defined): Int(defined.rawValue)
    case .applicationCode(let code), .privateCode(let code): Int(code)
    default: 1005
    }
  }
}
