# swift-obs-websocket

[![Tests](https://github.com/omnypro/swift-obs-websocket/actions/workflows/test.workflow.yml/badge.svg)](https://github.com/omnypro/swift-obs-websocket/actions/workflows/test.workflow.yml)
[![Join the chat at https://discord.gg/](https://img.shields.io/badge/discord-join%20chat-7289DA.svg)](https://discord.gg/)

> OBS WebSocket package for Swift.

## Install

Open the project manager and select your project. Make sure the project itself is selected in the right-hand panel. Select the **Package dependencies** tab. Press the plus icon. Enter the URL below and press enter.

```
https://github.com/omnypro/swift-obs-websocket#v1.0.0
```

## Usage

### Connect

```swift
let obsHostName = "localhost"
let obsHostPort = 4455

let obsWebSocket = OBSWebSocket()

obsWebSocket.connect(host: obsHostName, port: obsHostPort)
```

### Disconnect

> Disconnect from the OBS WebSocket.

```csharp
obsWebSocket.disconnect()
```

### Get Version

> Get the OBS and RPC version.

```csharp
obsWebSocket.requestGetVersion()
```

```csharp
print(obsWebSocket.obsWebSocketVersion)
print(obsWebSocket.rpcVersion)
```

### Get Scene List

> Get the scene list as a array of names.

```csharp
obsWebSocket.requestGetSceneList()
```

```csharp
for sceneName in obsWebSocket.sceneList {
    print(sceneName)
}
```

### Get Current Scene

> Get the current scene name.

```csharp
obsWebSocket.requestGetCurrentScene()
```

```csharp
print(obsWebSocket.currentSceneName)
```

### Set Current Scene

> Set the scene using a scene name.

```csharp
obsWebSocket.requestSetCurrentScene("1Password")
```

### Set Scene Transition Override

> Set the scene to use a specific override. `Cut` is the default.

```csharp
obsWebSocket.requestSetSceneTransitionOverride("1Password")
```

```csharp
obsWebSocket.requestSetSceneTransitionOverride("1Password", "Cut")
```

## Build

```bash
$ make build
```

## Tests

```bash
$ make test
```

## Support

[![](https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/avalonstar/)

## OmnyPro Team

|                                                        Bryan                                                        |                                                         Dave                                                          |                                                      Scott                                                      |
| :-----------------------------------------------------------------------------------------------------------------: | :-------------------------------------------------------------------------------------------------------------------: | :-------------------------------------------------------------------------------------------------------------: |
| <a href="https://github.com/bryanveloso/"><img src="https://avatars.githubusercontent.com/u/1258" width="64" /></a> | <a href="https://github.com/davemcnally/"><img src="https://avatars.githubusercontent.com/u/342029" width="64" /></a> | <a href="https://github.com/neogeek/"><img src="https://avatars.githubusercontent.com/u/6753" width="64" /></a> |

## License

This project is licensed under [The MIT License (MIT)](./LICENSE)
