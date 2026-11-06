# Face Unlock for Dux Shell

A settings panel for [Howdy](https://github.com/nathawatc/howdy-next) face unlock in [Dux Shell (DMS)](https://github.com/duxlabs-dev/dux-shell), so you can manage it without the terminal.

> **Status: early (0.1.0).** Tested on one machine: Arch Linux, Hyprland 0.57, DMS 2.1 and Howdy Next 3.4.

## Features

- **On/off switch**, in the panel and as a Control Center tile
- **Face samples:** add, name and remove them
- **Live camera preview,** off until you ask for it
- **Recognition test** that shows the match score against the score needed, so you can see how close each attempt was
- **Lock screen setup** with one switch
- **Tuning:** scan time, strictness, low-light tolerance and camera choice
- **Status** for `sudo`, admin prompts and the login screen (shown only, never changed)

## Requirements

- Dux Shell 2.0 or newer
- [Howdy Next](https://github.com/nathawatc/howdy-next), with its models downloaded (`sudo howdy download-models`) and a camera set
- `jq` and polkit

## Install

```sh
git clone https://github.com/nsssayom/dms-face-unlock.git
cd dms-face-unlock

sudo make install-system   # the helper and polkit policy
make link                  # adds the plugin to the shell
dms restart
```

Then turn on **Face Unlock** in Settings → Plugins and click its gear icon.

To remove it, turn the plugin off, then run `make unlink` and `sudo make uninstall-system`. If you enabled the lock screen switch, turn it off first.

## Security

**Face recognition is a convenience, not stronger security.** A regular camera without infrared can be fooled by a photo. Your password always keeps working as a fallback.

Managing Howdy requires root, so the plugin uses a small helper, [`system/faceunlock-helper`](system/faceunlock-helper), through polkit:

| Action | Password needed? |
|---|---|
| View status, run a recognition test | No, in your active local session |
| Add or remove samples, change settings, use the switches | Yes, then remembered for a few minutes |

The password requirement means nothing running as you can silently enroll someone else's face.

The helper:

- Takes the user from polkit (`PKEXEC_UID`), never from an argument
- Checks every value against an allowlist before passing it to Howdy
- Only edits the lock screen's PAM file if it created that file, and leaves custom files alone
- Never touches `sudo`, admin prompt or login PAM files

## Good to know

- **The lock screen needs a key press.** The shell starts authentication only when you submit, so press Enter, then look at the camera.
- **Keep the login screen on your password.** A face login can't unlock your keyring, so apps like Chrome would ask for its password.
- **After changing the lock screen switch, restart the shell.** It reads that setting only at startup, and the panel offers a button for this.
- **The camera handles one app at a time.** During a video call, the scan may fail and fall back to your password.

## Development

```sh
make link     # the shell loads the plugin straight from this folder
make check    # shellcheck, then the helper tests (uses sudo)
```

The tests replace Howdy and the camera with stubs in a temp folder, so they never touch your real configuration. After changing the helper, run `sudo make install-system` again.

## License

[MIT](LICENSE)
