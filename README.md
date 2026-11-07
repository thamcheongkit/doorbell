# macos-notifier

A background service that shows HTTP requests as macOS notifications. It uses only what ships with macOS (Perl, `osascript`, launchd), so it needs no Xcode or Command Line Tools.

## Install

**From the DMG:** download `macos-notifier.dmg` from the latest run of the [Build DMG workflow](../../actions/workflows/build-dmg.yml), open it, and double-click `Install.command`. The DMG is unsigned, so macOS blocks it the first time: open System Settings > Privacy & Security and choose **Open Anyway**.

**From source:** run this on the Mac or from an OrbStack Linux machine:

```sh
./install.sh
```

Either way, the service is copied to `~/Library/Application Support/macos-notifier` on the Mac and starts at login. Re-run the installer after changing `notifier.pl`.

The first time, allow notifications for **Script Editor** in System Settings > Notifications. macOS shows them under that name.

## Send a notification

From an app on the Mac:

```sh
curl -d '{"title":"Build","message":"Finished"}' http://127.0.0.1:8765/notify
```

From the OrbStack Linux machine, prefix the command with `mac`, because the service only listens on the Mac's localhost:

```sh
mac curl -d '{"title":"Build","message":"Finished"}' http://127.0.0.1:8765/notify
```

| Field | Required | Default |
| --- | --- | --- |
| `message` | yes | |
| `title` | no | `Notifier` |

`GET /health` returns `{"status":"ok"}`.

Requests with an `Origin` header are rejected, so web pages open in a browser can't send notifications. Bodies are limited to 64 KB.

## Troubleshooting

Logs are in `~/Library/Logs/macos-notifier.log` on the Mac.

If the API returns `sent` but nothing appears, check the Script Editor notification setting and Focus mode.

## Uninstall

Double-click `Uninstall.command` in the DMG, or run:

```sh
./uninstall.sh
```

## Build the DMG

GitHub Actions builds the DMG on every push to `master`. To build it locally on a Mac, run `./build-dmg.sh`; the output is `dist/macos-notifier.dmg`.
