import XCTest

@testable import OBSWebSocket

final class OBSWebSocketTests: XCTestCase {
  func testParseAuthentication() {
    var challenge: String = ""
    var salt: String = ""

    OBSWebSocket.parseAuthentication(
      [
        "authentication": [
          "challenge": "challenge",
          "salt": "salt",
        ]
      ] as [String: AnyObject], authenticationChallenge: &challenge, authenticationSalt: &salt)

    XCTAssertEqual(challenge, "challenge")
    XCTAssertEqual(salt, "salt")
  }

  func testParseCurrentProgramSceneChanged() {
    var currentSceneName: String = ""

    OBSWebSocket.parseCurrentProgramSceneChanged(
      [
        "eventData": [
          "sceneName": "Scene"
        ]
      ] as [String: AnyObject], currentSceneName: &currentSceneName)

    XCTAssertEqual(currentSceneName, "Scene")
  }

  func testParseGetSceneListResponse() {
    var currentSceneName: String = ""
    var sceneList: [String] = []

    OBSWebSocket.parseGetSceneListResponse(
      [
        "responseData": [
          "currentProgramSceneName": "Scene",
          "scenes": [
            ["sceneName": "Scene"],
            ["sceneName": "1Password"],
            ["sceneName": "Discord"],
            ["sceneName": "Slack"],
          ],
        ]
      ] as [String: AnyObject], sceneList: &sceneList, currentSceneName: &currentSceneName)

    XCTAssertEqual(currentSceneName, "Scene")
    XCTAssertEqual(sceneList.count, 4)
  }

  func testParseVersion() {
    var versionMajor: Int = 0
    var versionMinor: Int = 0
    var versionPatch: Int = 0

    OBSWebSocket.parseVersion(
      [
        "obsWebSocketVersion": "1.2.3"
      ] as [String: AnyObject], versionMajor: &versionMajor, versionMinor: &versionMinor,
      versionPatch: &versionPatch)

    XCTAssertEqual(versionMajor, 1)
    XCTAssertEqual(versionMinor, 2)
    XCTAssertEqual(versionPatch, 3)
  }

  func testGeneratingAuthenticationString() {
    let password = "password"

    let salt = "/VocefdXaHR5a335ushfuNQ6tCpZrsThySZeEKgVvIw="
    let challenge = "n0yPFTtDDv2I/ht/WRInBrIbm9l8gJqgjQbaMDcbYUU="

    let input = OBSWebSocket.generateAuthenticationString(
      password: password, salt: salt, challenge: challenge)
    let expectedOutput = "aKogKyKL/o3LnCteTaxUiuYEd7u5bljjZgvbNRmZWPE="

    XCTAssertEqual(input, expectedOutput)
  }
}
