# KxFrameControllerManager

[日本語](README.md) | English

KxFrameControllerManager disconnects a Steam Frame controller (equivalent to powering it off) when you hold one of its buttons.
It runs in the background on the headset and can be operated from inside VR.
While both controllers are disconnected, it can also lower screen brightness and rendering quality to save battery and reduce heat (disabled by default).

## Features

- Hold View on the left controller, or Menu on the right controller, for 2 seconds to disconnect that controller
- A disconnected controller reconnects when you press a button on it
- A "KxFCM" tab in the SteamVR dashboard lets you check status, disconnect right away, change buttons, timings and power saving, update, and switch the display language
- New versions are checked for and installed automatically. If a new version fails to start, the previous version is restored

## Requirements

- Steam Frame (SteamOS), with a way to run commands in a terminal on the headset
- SteamVR

While SteamVR is not running, the tool waits without doing anything.

## Installation

Run the following line in a terminal on the headset.
You can open a terminal with Konsole in desktop mode, or over ssh from a PC after enabling Developer Mode.

```sh
curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash
```

This installs the latest stable release, registers it to run whenever you are logged in, and starts it.
sudo is not required, and nothing is written outside your home directory.

After installing, start SteamVR, connect both controllers, and check with the following command.

```sh
~/.local/bin/kx-frame-controller-manager status
```

If you see `SteamVR: connected`, `27062: reachable`, and `the OpenVR and 27062 serials match` for each hand, it is ready.
How to install a specific version, or install the tar.gz by hand, is described in the [setup guide](docs/setup.md) (Japanese).

## Usage

### Disconnecting a controller

Hold the button on the controller you want to disconnect.
By default this is View on the left and Menu on the right.

1. After 1 second, the controller vibrates once briefly. This is a warning; release the button now to cancel
2. After 2 seconds, it vibrates twice briefly and the controller you pressed is disconnected

To reconnect a disconnected controller, press any of its buttons.

### Settings tab

While the tool is running and connected to SteamVR, a "KxFCM" tab appears in the row at the bottom of the SteamVR dashboard.
Open it and use the controller pointer.
Changes are saved and applied immediately.

The top of the screen shows the status.

| Item | Meaning |
| --- | --- |
| SteamVR | Whether the tool is connected to SteamVR |
| Left, Right | Whether each controller is connected |
| Disconnect | Whether the mechanism used to disconnect controllers (a web server inside SteamVR) responds. If it does not, neither a long press nor the on-screen buttons can disconnect |
| Power saving | Whether power saving is in use or active |

The Left, Right and Both buttons under "Disconnect now" disconnect without a long press.
To avoid accidental touches, they only act when pressed twice. The first press is cancelled after 4 seconds.

The screen has the following tabs. Values change one step at a time with the left and right arrows or − and +.

| Tab | What you can change |
| --- | --- |
| Long press | Whether a long press disconnects, the button for each hand, time to disconnect, time to the warning vibration, pause after a disconnect, which side to disconnect (the pressed side or both), input priority |
| Vibration & power | Whether to vibrate before disconnecting and how strongly, power saving settings |
| Update | Automatic updates and the check interval. The current version and the time of the last check are also shown |
| General | Display language (the default, "Auto", follows the Steam display language), and whether to start automatically with Frame. You can also quit the tool here |

A change of the long press button takes effect after you close the dashboard.
If you assign a button to KxFrameControllerManager in the SteamVR controller binding screen, that binding takes precedence.

### Using power saving

Power saving lowers rendering quality once both controllers have been disconnected for 10 seconds.
Everything is restored when either controller reconnects.

It is disabled by default.
To use it, turn on "Save power when both are off" in the "Vibration & power" tab.
To lower the screen brightness as well, also turn on "Lower the brightness" in the same tab. This is also off by default.

## Updating

By default, the tool checks for a new version every 6 hours, and if one exists, installs it and restarts.
If the new version fails to start, the previous version is restored.

To update without waiting, press "Update now" twice in the "Update" tab of the settings screen.
The tool restarts when a new version is installed, so the tab disappears once and comes back.
You can also update from a terminal with the following command. Running the installation line again does the same.

```sh
~/.local/bin/kx-frame-controller-manager update
```

To stop automatic updates, turn off "Update automatically" in the "Update" tab.

## Quitting and autostart

To stop the tool, press "Quit KxFCM" twice in the "General" tab of the settings screen.
The tab disappears when the tool quits.
The tool starts again the next time Frame starts.
To bring it back right away, choose "KxFrameControllerManager" from "Launch a program" in the VR menu.
Running the following command in a terminal does the same.

```sh
~/.local/bin/kx-frame-controller-manager start
```

If you do not want the tool to start with Frame, turn off "Start automatically with Frame" in the same tab.
Turning it off does not stop the running tool.
From then on, the tool runs only when you choose it from "Launch a program" or run `start` above.
From a terminal, `autostart on` and `autostart off` switch it, and `autostart` alone shows the current state.

## Uninstalling

The following command stops the background service and automatic updates and removes their registration.

```sh
~/.local/bin/kx-frame-controller-manager uninstall
```

This leaves the executable and settings in place.
To remove everything, run the following as well.

```sh
rm -f ~/.local/bin/kx-frame-controller-manager ~/.local/bin/kx-frame-controller-manager.old
rm -rf ~/.config/KxFrameControllerManager ~/.local/share/KxFrameControllerManager ~/.local/state/KxFrameControllerManager
```

If you used power saving, first make sure that `~/.local/state/KxFrameControllerManager/power_save.json` does not exist.
If the file is still there, the brightness and rendering settings changed by power saving have not been restored yet.
Start the tool once while SteamVR is running to restore them.

## Troubleshooting

Start by running `status` to see where things stop.

```sh
~/.local/bin/kx-frame-controller-manager status
```

- **`SteamVR: not connected`**: check that SteamVR is running. If it is, see "うまく動かないとき" (troubleshooting) in the [setup guide](docs/setup.md#うまく動かないとき) (Japanese)
- **`27062: not reachable`** (shown as "Disconnect: unavailable" on the settings screen): the mechanism inside SteamVR that disconnects controllers is not responding. Restart SteamVR and try again. A SteamVR update may also have broken it
- **The serials do not match**: for safety, that hand is never disconnected by a long press. Reconnect the controller and run `status` again
- **The long press does nothing only while in a game**: the game may be taking the input. Set "Input priority" to "Highest" in the "Long press" tab and enable "Experimental overlay input overrides" in SteamVR. The assigned button then no longer works inside the game
- **The "KxFCM" tab does not appear**: check that the tool is running with `systemctl --user status kx-frame-controller-manager`. If it is not, start it with `~/.local/bin/kx-frame-controller-manager start`

Logs are available with `journalctl --user -u kx-frame-controller-manager`.
They are also kept per day in `~/.local/state/KxFrameControllerManager/logs/`.
If the problem remains, please report it in a [GitHub issue](https://github.com/limit7412/KxFrameControllerManager/issues) with the logs attached.

## Documentation

The following documents are written in Japanese.

- [Setup guide](docs/setup.md): installation details, file locations, managing the background service
- [Configuration reference](docs/configuration.md): every item in the config file
- [Development status](docs/status.md): implemented features, and what has and has not been verified on real hardware
- [Architecture](docs/architecture.md)
- [Development guide](docs/development.md)
- [Messages on 27062](docs/protocol-27062.md)

## License

MIT License. Notices for third-party software are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
