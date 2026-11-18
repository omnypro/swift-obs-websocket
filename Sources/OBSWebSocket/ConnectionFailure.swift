import Network

/// Why the last connection attempt or session ended.
///
/// A client reads it from `WebSocket.failure` and chooses its own words. The value stays until a
/// session becomes ready or the client calls `disconnect()`.
public enum ConnectionFailure: Equatable, Sendable {
  /// The host or port does not form a WebSocket address.
  case invalidAddress
  /// The host name did not resolve.
  case hostNotFound
  /// Nothing accepted the connection on that port.
  case refused
  /// The host did not answer in time, or no route to it exists.
  case timedOut
  /// macOS blocked the connection to a device on the local network.
  case localNetworkDenied
  /// OBS asked for a password and none was set.
  case authenticationRequired
  /// OBS closed the session with an authentication failure.
  case authenticationFailed
  /// OBS and this client share no protocol version.
  case unsupportedVersion
  /// OBS closed the session because of a protocol error.
  case closedByOBS
  /// The socket ended without an explanation: OBS quit, or the network dropped.
  case connectionLost

  /// The `kDNSServiceErr_PolicyDenied` code, which macOS reports when local network access is off.
  private static let dnsPolicyDenied: Int32 = -65570

  /// The failure behind an error reported while the connection was opening.
  ///
  /// No connection existed yet, so no case here means a lost one. A peer that resets the
  /// connection, answers something other than a WebSocket handshake, or fails in a way this does
  /// not name is not accepting a WebSocket connection.
  ///
  /// For a TCP connection to a device on the local network, macOS reports a blocked local network
  /// on the connection's path and gives an ordinary POSIX error, so the path reason comes first.
  init(networkError: NWError, pathReason: NWPath.UnsatisfiedReason? = nil) {
    if pathReason == .localNetworkDenied {
      self = .localNetworkDenied

      return
    }

    switch networkError {
    case .posix(let code):
      switch code {
      case .ECONNREFUSED:
        self = .refused

      case .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
        self = .timedOut

      default:
        self = .refused
      }

    case .dns(let code):
      self = code == ConnectionFailure.dnsPolicyDenied ? .localNetworkDenied : .hostNotFound

    default:
      self = .refused
    }
  }

  /// The failure behind a WebSocket close code. OBS defines codes 4000 to 4012.
  init(closeCode: Int) {
    switch closeCode {
    case 4009: self = .authenticationFailed
    case 4010: self = .unsupportedVersion
    case 4011: self = .connectionLost
    case 4000...4999: self = .closedByOBS
    default: self = .connectionLost
    }
  }
}
