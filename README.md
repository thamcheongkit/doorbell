# Doorbell

A menu bar app that shows HTTP requests as macOS notifications. Messages can use Markdown. The bell menu shows the service status, lists the last 10 notifications (cleared when the app quits), and can send a test notification.

Requires macOS 13 or later on Apple silicon.

## Install

1. Download `Doorbell.dmg` from the latest run of the [Build DMG workflow](../../actions/workflows/build-dmg.yml).
2. Open it and drag `Doorbell.app` to Applications. Without an admin account, use the `Applications` folder in your home folder instead, creating it if needed.
3. Open the app. It's unsigned, so macOS blocks it the first time: open System Settings > Privacy & Security and choose **Open Anyway**.
4. Choose **Allow** when asked about notifications.

The app starts at login once it's in either Applications folder. To turn that off, use System Settings > General > Login Items.

## Send a notification

From an app on the Mac:

```sh
curl -d '{"title":"Build","message":"Finished"}' http://127.0.0.1:8765/notify
```

From an OrbStack Linux machine, prefix the command with `mac`:

```sh
mac curl -d '{"title":"Build","message":"Finished"}' http://127.0.0.1:8765/notify
```

From another device, use the Mac's hostname and a token. Choose **Copy Token** from the bell menu, or run `defaults read io.github.thamcheongkit.doorbell token` on the Mac:

```sh
curl -H "Authorization: Bearer $DOORBELL_TOKEN" \
  -d '{"title":"Build","message":"Finished"}' \
  http://your-mac:8765/notify
```

Requests use plain HTTP, so the token and messages are only protected on an encrypted network such as Tailscale. Avoid sending them over untrusted Wi-Fi.

| Field | Required | Default |
| --- | --- | --- |
| `message` | yes | |
| `title` | no | `Doorbell` |

`GET /health` returns `{"status":"ok"}`. It needs the token too when called from another device.

Requests with an `Origin` header are rejected, so web pages open in a browser can't send notifications. Bodies are limited to 64 KB.

## Markdown

`message` is always treated as Markdown. macOS banners only show plain text, so the banner shows the text without formatting. Click the banner, or choose the message under Recent in the bell menu, to open it fully formatted.

Headings, bold, italics, strikethrough, inline code, code blocks, lists, quotes, tables and web links are supported. Images aren't loaded.

To send a Markdown file, use `jq` to put it in the JSON body:

```sh
jq -n --rawfile message notes.md '{title: "Notes", message: $message}' |
  curl -d @- http://127.0.0.1:8765/notify
```

## Troubleshooting

If the API returns `sent` but nothing appears, check the app's setting in System Settings > Notifications and Focus mode.

## Uninstall

Choose **Quit** from the bell menu, then delete the app from Applications.

## Build

GitHub Actions builds the DMG on every push to `master`. To build it locally on a Mac with the Command Line Tools and `librsvg` (`brew install librsvg`), run `./build-dmg.sh`; the output is `dist/Doorbell.dmg`.

The app icon is generated from `icon.svg`.
