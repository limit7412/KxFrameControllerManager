# KxFrameControllerManager

[日本語](README.md) | English

KxFrameControllerManager runs in the background on a Steam Frame headset and disconnects a controller (equivalent to powering it off) when you hold an assigned button for a set time.
While both controllers are disconnected, it lowers screen brightness and rendering quality to save battery and reduce heat.

## Status

All features planned for v1 are in place.

- Reads the long press as a SteamVR Input action and sends a disconnect request to the SteamVR web server inside the headset (`127.0.0.1:27062`). The default bindings are a long press of View on the left controller and Menu on the right
- `status`, `list`, and `disconnect` check connectivity and controller matching, and can disconnect a controller without a long press
- A settings tab named "KxFCM" appears in the SteamVR dashboard. From it you can check status, disconnect manually, and configure button bindings, hold times, and power saving
- Runs as a systemd user unit. Installation is a single `curl ... | bash` line
- Power saving while both controllers are disconnected is implemented, but disabled by default until it has been verified on real hardware

On real hardware, it has been confirmed that a disconnect request to 27062 turns a controller off (2026-11-09).
Whether a background app can read SteamVR Input, and whether haptic feedback works, has not been verified yet.

## Requirements

- Steam Frame (SteamOS, aarch64) with Developer Mode enabled and ssh access
- SteamVR (the tool waits without doing anything while SteamVR is not running)

## Installation

Run the following line in a terminal on the headset.
You can open a terminal with Konsole in desktop mode, or over ssh from a PC.

```sh
curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash
```

This downloads the tar.gz of the latest stable release, runs the `install.sh` inside it, registers the systemd user unit, and starts it.
sudo is not required.
Running the same line again replaces the installation with the newest version and restarts it.

To install a prerelease, write `bash -s -- --prerelease` instead of `bash`. To install a specific version, write `bash -s -- --version 0.1.0`.
Details, including how to install the tar.gz by hand, are in the [setup guide](docs/setup.md) (Japanese).

## File locations

Everything is placed under the home directory; nothing is written outside `~`.

| File | Location |
| --- | --- |
| Executable | `~/.local/bin/kx-frame-controller-manager` |
| Configuration | `~/.config/KxFrameControllerManager/config.json` |
| vrmanifest and action manifest | `~/.local/share/KxFrameControllerManager/` |
| Logs | `~/.local/state/KxFrameControllerManager/logs/` |
| Values saved before power saving changed them | `~/.local/state/KxFrameControllerManager/power_save.json` |
| systemd unit | `~/.config/systemd/user/kx-frame-controller-manager.service` |

## Documentation

The following documents are written in Japanese.

- [Setup guide](docs/setup.md)
- [Configuration reference](docs/configuration.md)
- [Architecture](docs/architecture.md)
- [Development guide](docs/development.md)
- [Messages on 27062](docs/protocol-27062.md)

## License

MIT License. Notices for third-party software are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
