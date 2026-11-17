import Testing

@testable import OBSWebSocket

struct OBSWebSocketParsingTests {
  @Test(
    arguments: [
      ("1.2.3", 1, 2, 3),
      ("5.1", 5, 1, 0),
      ("5", 5, 0, 0),
      ("5.5.4-beta", 5, 5, 4),
    ])
  func readsAVersionWithMissingParts(
    version: String, major: Int, minor: Int, patch: Int
  ) {
    var versionMajor = 0
    var versionMinor = 0
    var versionPatch = 0

    OBSWebSocket.parseVersion(
      ["obsWebSocketVersion": version] as [String: AnyObject],
      versionMajor: &versionMajor, versionMinor: &versionMinor, versionPatch: &versionPatch)

    #expect([versionMajor, versionMinor, versionPatch] == [major, minor, patch])
  }

  @Test func leavesTheVersionAloneWhenItHasNoNumber() {
    var versionMajor = 7
    var versionMinor = 8
    var versionPatch = 9

    OBSWebSocket.parseVersion(
      ["obsWebSocketVersion": "beta"] as [String: AnyObject],
      versionMajor: &versionMajor, versionMinor: &versionMinor, versionPatch: &versionPatch)

    #expect([versionMajor, versionMinor, versionPatch] == [7, 8, 9])
  }

  @Test func skipsAScenesWithoutAName() {
    var sceneList: [String] = []
    var currentSceneName = ""

    OBSWebSocket.parseGetSceneListResponse(
      [
        "responseData": [
          "currentProgramSceneName": "Scene",
          "scenes": [["sceneName": "Scene"], ["sceneName": 42], ["other": "x"]],
        ]
      ] as [String: AnyObject], sceneList: &sceneList, currentSceneName: &currentSceneName)

    #expect(sceneList == ["Scene"])
  }
}
