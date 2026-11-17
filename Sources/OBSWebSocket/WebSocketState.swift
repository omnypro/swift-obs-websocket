public enum WebSocketState: Sendable {
  /// No connection has been attempted yet.
  case idle
  case startingUp
  case connected
  case disconnected
}
