import Foundation

@available(macOS 10.15, *)
public class WebSocket: NSObject, IWebSocket, ObservableObject, URLSessionWebSocketDelegate {
  @Published public var state: WebSocketState = .None

  internal var webSocketTask: URLSessionWebSocketTask?

  /// How long a connection may stay in `.StartingUp` before it is given up.
  public var connectionTimeout: TimeInterval = 5

  private var timeoutDispatch: DispatchWorkItem?

  /// The WebSocket URL for a host the user typed, or `nil` when the host cannot form one.
  static func makeURL(host: String, port: Int) -> URL? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else { return nil }

    let isBareIPv6 = trimmed.contains(":") && !trimmed.hasPrefix("[")

    return URL(string: "ws://\(isBareIPv6 ? "[\(trimmed)]" : trimmed):\(port)")
  }

  public func connect(host: String = "localhost", port: Int = 4455) {
    disconnect()

    guard let url = WebSocket.makeURL(host: host, port: port) else {
      state = .Disconnected
      return
    }

    let session = URLSession(
      configuration: .default, delegate: self, delegateQueue: OperationQueue())

    webSocketTask = session.webSocketTask(with: url)

    state = .StartingUp

    webSocketTask?.resume()

    receiveMessage()

    let timeout = DispatchWorkItem { [weak self] in
      if self?.state == .StartingUp {
        self?.disconnect()
      }
    }

    timeoutDispatch = timeout

    DispatchQueue.main.asyncAfter(deadline: .now() + connectionTimeout, execute: timeout)
  }

  public func receiveMessage() {
    webSocketTask?.receive { [weak self] result in
      switch result {
      case .success(let message):
        switch message {
        case .string(let text):
          self?.handleMessage(text)
        default:
          break
        }

        if self?.webSocketTask?.state == URLSessionTask.State.running {
          self?.receiveMessage()
        }

      case .failure(let error):
        print(error.localizedDescription)
      }
    }
  }

  public func handleMessage(_ message: String) {
    print(message)
  }

  public func sendMessage(_ message: String) {
    if webSocketTask?.state != URLSessionTask.State.running {
      return
    }

    let message = URLSessionWebSocketTask.Message.string(message)

    webSocketTask?.send(message) { error in
      if let error = error {
        print(error.localizedDescription)
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
      print(error.localizedDescription)
    }
  }

  public func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    DispatchQueue.main.async {
      self.state = .Connected

      self.timeoutDispatch?.cancel()
    }
  }

  public func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    DispatchQueue.main.async {
      self.disconnect()
    }
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if error != nil {
      DispatchQueue.main.async {
        self.disconnect()
      }
    }
  }

  public func disconnect() {
    guard state == .Connected || state == .StartingUp else { return }

    self.state = .Disconnected

    timeoutDispatch?.cancel()

    webSocketTask?.cancel(with: .normalClosure, reason: nil)
  }

  deinit {
    timeoutDispatch?.cancel()

    webSocketTask?.cancel(with: .goingAway, reason: nil)
  }
}
