import Foundation

@available(macOS 10.15, *)
public class WebSocket: NSObject, IWebSocket, ObservableObject, URLSessionWebSocketDelegate {
  @Published public var state: WebSocketState = .None

  internal var webSocketTask: URLSessionWebSocketTask?

  private let timeoutInSeconds: Double = 5

  private var timeoutDispatch: DispatchWorkItem?

  public func connect(host: String = "localhost", port: Int = 4455) {
    disconnect()

    let session = URLSession(
      configuration: .default, delegate: self, delegateQueue: OperationQueue())

    webSocketTask = session.webSocketTask(with: URL(string: "ws://\(host):\(port)")!)

    state = .StartingUp

    webSocketTask?.resume()

    receiveMessage()

    timeoutDispatch = DispatchWorkItem { [weak self] in
      if self?.webSocketTask?.state != URLSessionTask.State.running {
        self?.disconnect()
      }
    }

    DispatchQueue.global().asyncAfter(
      deadline: .now() + timeoutInSeconds,
      execute: timeoutDispatch!)
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
    _ session: URLSession, webSocketTask: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if error != nil {
      DispatchQueue.main.async {
        self.disconnect()
      }
    }
  }

  public func disconnect() {
    if self.state != .Connected {
      return
    }

    self.state = .Disconnected

    timeoutDispatch?.cancel()

    webSocketTask?.cancel(with: .normalClosure, reason: nil)
  }

  deinit {
    timeoutDispatch?.cancel()

    webSocketTask?.cancel(with: .goingAway, reason: nil)
  }
}
