# macos-notifier

A background service that shows HTTP requests as macOS notifications. It uses only what ships with macOS (Perl, `osascript`, launchd), so it needs no Xcode or Command Line Tools.

## Install

Run from the OrbStack Linux machine:

```sh
./install.sh
```

This copies the service to `~/Library/Application Support/macos-notifier` on the Mac and starts it at login. Re-run it after changing `notifier.pl`.

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

```sh
./uninstall.sh
```
