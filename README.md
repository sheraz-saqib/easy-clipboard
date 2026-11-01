<p align="center">
  <img src="assets/icon.png" width="128" alt="Easy Clipboard icon">
</p>

<h1 align="center">Easy Clipboard</h1>

<p align="center">
  A fast, private clipboard history for macOS. Press <b>⌃V</b> and pick anything you copied.
</p>

<p align="center">
  <a href="https://github.com/sheraz-saqib/mac-silicon-easyclipboard-app/releases/latest/download/EasyClipboard.dmg">
    <img src="https://img.shields.io/badge/Download-EasyClipboard.dmg-2b2d33?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS">
  </a>
  <br>
  <sub>Apple Silicon (M1–M4) · macOS 14 Sonoma or later · Free & open source</sub>
</p>

---

## Features

- **⌃V** opens your history right next to your text cursor
- Search, and filter by **Text**, **Images**, **Numbers** or **Favorites**
- **Favorites** ⭐ are kept forever, even when you clear the history
- Edit, copy or delete any item
- Lives in the menu bar, no Dock icon

## Shortcuts

| Key | Action |
|---|---|
| `⌃V` | Open / close history |
| `↑` `↓` | Move selection |
| `↩` | Paste selected item |
| `⇥` | Next filter |
| `⌘D` | Add / remove favorite |
| `⌘E` | Edit |
| `⌘⌫` | Delete |
| `esc` | Close |

## Private by design

- **Everything stays on your Mac.** Easy Clipboard has no servers, no account, no analytics, and no network code at all.
- **Encrypted.** Your history and images are stored encrypted (AES‑256). The key is kept in your macOS Keychain.
- **Passwords are skipped.** Items that password managers mark as secret are never saved.
- **Clean uninstall.** Use **Uninstall Easy Clipboard…** in the menu bar, or drag the app to the Trash while it's running. Either way, all its data and the Keychain key are deleted.
- **Open source.** Every line of code is in this repo for you to check.

## Install

1. Download **EasyClipboard.dmg** and drag **Easy Clipboard** into **Applications**.
2. Open it. macOS will warn you because the app isn't from the App Store. Click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. You only need to do this once.
3. When asked, turn on **Accessibility** for Easy Clipboard. It needs this to paste for you and to open at your cursor.
4. Press **⌃V** in any text field.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh install   # build and install to /Applications
./build.sh dmg       # build build/EasyClipboard.dmg
```
