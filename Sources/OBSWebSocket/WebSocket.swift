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

  /// How long a connection may stay in `.startingUp` before it is given up.
  public var connectionTimeout: TimeInterval = 5

  /// The largest message the socket accepts, in bytes. OBS messages are far smaller.
  nonisolated static let maximumMessageSize = 8 * 1024 * 1024

  @ObservationIgnored private var connection: NWConnection?
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?

  public init() {}

  /// The `host:port` pair for a host the user typed, or `nil` when the host is empty.
  nonisolated static func makeAuthority(host: String, port: Int) -> String? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else { return nil }

    let isBareIPv6 = trimmed.contains(":") && !trimmed.hasPrefix("[")

    return "\(isBareIPv6 ? "[\(trimmed)]" : trimmed):\(port)"
  }

  /// The WebSocket URL for a host the user typed, or `nil` when the host cannot form one.
  nonisolated static func makeURL(host: String, port: Int) -> URL? {
    guard let authority = makeAuthority(host: host, port: port) else { return nil }

    return URL(string: "ws://\(authority)")
  }

  public func connect(host: String = "localhost", port: Int = 4455) {
    disconnect()

    guard let authority = WebSocket.makeAuthority(host: host, port: port),
      let url = WebSocket.makeURL(host: host, port: port)
    else {
      state = .disconnected
      return
    }

    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    options.maximumMessageSize = WebSocket.maximumMessageSize

    // Network.framework leaves the port out of the Host header. RFC 6455 wants it for a
    // port other than 80, and a proxy in front of OBS can route on it.
    options.setAdditionalHeaders([(name: "Host", value: authority)])

    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

    let connection = NWConnection(to: .url(url), using: parameters)

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

  public func disconnect() {
    guard state == .connected || state == .startingUp else { return }

    state = .disconnected

    timeoutTask?.cancel()
    timeoutTask = nil

    if let connection {
      self.connection = nil
      WebSocket.close(connection)
    }
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
  }

  private func connectionStateChanged(_ newState: NWConnection.State, of connection: NWConnection) {
    guard connection === self.connection else { return }

    switch newState {
    case .ready:
      state = .connected

      timeoutTask?.cancel()

      receiveMessage(from: connection)

    case .waiting(let error), .failed(let error):
      // `.waiting` is where a refused connection or a failed lookup lands, and the
      // connection would retry it for as long as it lives.
      logger.error("Connecting failed: \(error.localizedDescription, privacy: .public)")

      disconnect()

    case .cancelled:
      disconnect()

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

  private func received(
    _ data: Data?, context: NWConnection.ContentContext?, error: NWError?,
    from connection: NWConnection
  ) {
    guard connection === self.connection else { return }

    if let error {
      logger.error("Receiving failed: \(error.localizedDescription, privacy: .public)")

      disconnect()
      return
    }

    let metadata =
      context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
      as? NWProtocolWebSocket.Metadata

    switch metadata?.opcode {
    case .close:
      disconnect()

    case .text:
      if let data, let text = String(data: data, encoding: .utf8) {
        handleMessage(text)
      }

      receiveMessage(from: connection)

    default:
      receiveMessage(from: connection)
    }
  }

  private func connectionTimedOut(_ connection: NWConnection) {
    guard connection === self.connection, state == .startingUp else { return }

    disconnect()
  }
}
