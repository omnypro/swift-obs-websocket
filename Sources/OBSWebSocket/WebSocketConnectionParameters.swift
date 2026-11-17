import Network

/// The Network.framework parameters every OBS connection uses.
enum WebSocketConnectionParameters {
  static func make() -> NWParameters {
    let webSocket = NWProtocolWebSocket.Options()
    webSocket.autoReplyPing = true
    webSocket.maximumMessageSize = WebSocket.maximumMessageSize

    // OBS is often on another machine. One that sleeps or drops off the network sends no close,
    // so the connection would read as live until the system gave up on it. Probes after ten idle
    // seconds, then every five, end it after about 25 seconds.
    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 3

    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

    return parameters
  }
}
