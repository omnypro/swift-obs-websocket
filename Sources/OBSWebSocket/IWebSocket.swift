import Foundation

protocol IWebSocket {
  func connect(host: String, port: Int)

  func receiveMessage()

  func handleMessage(_ message: String)

  func sendMessage(_ message: String)

  func sendDictionary(_ dict: Any)

  func disconnect()
}
