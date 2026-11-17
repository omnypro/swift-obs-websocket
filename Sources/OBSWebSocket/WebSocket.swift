import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "pro.omny.OBSWebSocket", category: "WebSocket")

/// A WebSocket client whose state SwiftUI can observe.
@MainActor @Observable
public class WebSocket {
  public var state: WebSocketState = .idle

  /// How long a connection may stay in `.startingUp` before it is given up.
  public var connectionTimeout: TimeInterval = 5

  @ObservationIgnored private var session: URLSession?
  @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?

  public init() {}

  /// The WebSocket URL for a host the user typed, or `nil` when the host cannot form one.
  nonisolated static func makeURL(host: String, port: Int) -> URL? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else { return nil }

    let isBareIPv6 = trimmed.contains(":") && !trimmed.hasPrefix("[")

    return URL(string: "ws://\(isBareIPv6 ? "[\(trimmed)]" : trimmed):\(port)")
  }

  public func connect(host: String = "localhost", port: Int = 4455) {
    disconnect()

    guard let url = WebSocket.makeURL(host: host, port: port) else {
      state = .disconnected
      return
    }

    let session = URLSession(
      configuration: .default, delegate: SessionDelegate(socket: self), delegateQueue: nil)
    let task = session.webSocketTask(with: url)

    self.session = session
    webSocketTask = task
    state = .startingUp

    task.resume()

    receiveMessage(from: task)

    timeoutTask = Task { [weak self, connectionTimeout] in
      try? await Task.sleep(for: .seconds(connectionTimeout))

      guard !Task.isCancelled else { return }

      self?.connectionTimedOut(task)
    }
  }

  public func handleMessage(_ message: String) {
    logger.debug("Received a message: \(message, privacy: .private)")
  }

  public func sendMessage(_ message: String) {
    guard let task = webSocketTask, task.state == .running else { return }

    task.send(.string(message)) { error in
      if let error {
        logger.error("Sending failed: \(error.localizedDescription, privacy: .public)")
      }
    }
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

    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil

    session?.finishTasksAndInvalidate()
    session = nil
  }

  isolated deinit {
    timeoutTask?.cancel()
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    session?.finishTasksAndInvalidate()
  }

  private func receiveMessage(from task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        self?.received(result, from: task)
      }
    }
  }

  private func received(
    _ result: Result<URLSessionWebSocketTask.Message, Error>, from task: URLSessionWebSocketTask
  ) {
    guard task === webSocketTask else { return }

    switch result {
    case .success(let message):
      if case .string(let text) = message {
        handleMessage(text)
      }

      if task.state == .running {
        receiveMessage(from: task)
      }

    case .failure(let error):
      logger.error("Receiving failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func connectionTimedOut(_ task: URLSessionWebSocketTask) {
    guard task === webSocketTask, state == .startingUp else { return }

    disconnect()
  }

  fileprivate func connectionOpened(_ task: URLSessionTask) {
    guard task === webSocketTask else { return }

    state = .connected

    timeoutTask?.cancel()
  }

  fileprivate func connectionEnded(_ task: URLSessionTask) {
    guard task === webSocketTask else { return }

    disconnect()
  }
}

/// Reports what URLSession says about one connection back to the socket on the main actor.
///
/// Every callback names the task it came from. The socket ignores a task it has already
/// replaced, so a late failure from an old connection cannot end the new one.
private final class SessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  private weak var socket: WebSocket?

  init(socket: WebSocket) {
    self.socket = socket
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    let socket = socket

    Task { @MainActor in
      socket?.connectionOpened(webSocketTask)
    }
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let socket = socket

    Task { @MainActor in
      socket?.connectionEnded(webSocketTask)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard error != nil else { return }

    let socket = socket

    Task { @MainActor in
      socket?.connectionEnded(task)
    }
  }
}
