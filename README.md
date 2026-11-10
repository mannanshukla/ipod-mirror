# iPod Mirror

A native macOS USB viewer for a jailbroken iPod running Veency, with a minimal frame, a slim glass control bar, and the original website iPod image as its icon. This is an early prototype, not Apple's iPhone Mirroring service.

## Run

Open `build/iPod Mirror.app`. Plug in the iPod, enable Veency in its Settings, unlock the screen, open Connection settings and select its USB identifier, and click Connect. Accept Veency's access request on the iPod if shown. If Veency has a password, enter it in the Mac app. The password is kept in memory only.

- The compact glass bar keeps Home, Lock, Screenshot, Audio, and Settings within reach. Connection settings is also available with Command-comma.
- Click to tap; drag to swipe.
- Click the screen, then type. Return, Backspace, Tab, Escape and arrow keys are supported. Unicode text depends on the device's Veency build; IME composition is not implemented.
- Home (Command-1) and Lock (Command-L) use Veency's documented mouse button mappings.
- Save a full-resolution PNG with Screenshot (Command-S).
- Disconnect stops the USB session. After an established connection drops, the viewer retries the same device until Stop is pressed. Initial connection/authentication failures require another Connect.

The USB device picker currently shows the last eight characters of each device identifier, not a friendly device name. Choose the iPod if multiple devices are attached. Modern stock iPhones cannot run this backend.

## Build and test

Requires macOS 13+ and Apple's Command Line Tools. The build targets Apple Silicon. The screen-first frame works on macOS 13 and later. The slim control bar uses system Liquid Glass on macOS 26+, with a native translucent fallback on earlier systems. No Xcode project, Homebrew dependencies, iproxy process, or network service is needed.

```sh
./build.sh
./test.sh
```

The app is locally ad-hoc signed, not notarized for public distribution. Protocol tests exercise RFB 3.3/3.8, authentication, partial frames, input packet encoding, resizing, invalid rectangles, and cancellation using local socket pairs. The DES response fixture is independently checked with OpenSSL using the VNC bit-reversed password key.

## Architecture and privacy

`Transport.swift` speaks plist usbmux to `/var/run/usbmuxd`, enumerates USB devices, and asks it to connect to the selected device's port 5900. `RFB.swift` implements RFB/VNC with raw rectangles and display resizing. `App.swift` supplies the AppKit window and input mapping.

Connection states are idle → connecting → connected → waiting (after a drop). A session generation rejects callbacks from old connections. Disconnect shuts down the socket to unblock pending reads; the owning Wire closes its descriptor on deallocation. Frame delivery coalesces to one pending frame on the main thread. Input writes run on a separate serial queue. Weak callbacks avoid retaining a session through its own frame handler.

The Mac app itself does not install anything on the iPod. Optional helper installation adds only its own files; it does not alter app databases. It does not read app databases, sync files, transmit telemetry, or share the clipboard. Screenshots are written only when requested. VNC's legacy password scheme is not modern encryption; this client connects only through the local USB service and does not open a network listener. Veency itself may also listen on the iPod's Wi-Fi interface; this app does not change that setting.

## Prototype limits

- Live 640 × 960 screen, taps, Home, swipe-to-Spotlight, and Mac keyboard input verified on iPod touch 4 / iOS 5.1.1. Disconnect and reconnect also verified after accepting Veency’s device-side access prompt. Automatic recovery after a physical cable unplug has not yet been tested.
- Veency remains required. It may need the iPod awake and an access prompt accepted.
- Raw screen updates favor compatibility over compression; actual frame rate depends on the iPod and Veency.
- No notification forwarding, clipboard sync, multitouch, or screen-off mirroring.
- Optional audio is experimental and does not mute the iPod speaker or provide timestamp-based audio/video synchronization.
- No claim of memory-leak-free operation; protocol cancellation and closure ownership are checked, but Instruments testing remains pending.

## References

- [RFB protocol, RFC 6143](https://www.rfc-editor.org/rfc/rfc6143)
- [Veency controls and setup](https://cydia.saurik.com/info/veency/)
- [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) for the USB service protocol

## Optional audio and direct video

Audio plays the iPod output mix on the Mac over USB. Startup buffering and TCP_NODELAY avoid the choppy playback observed in the first prototype. Music playback was confirmed smooth on the test device. Audio is enabled explicitly with the speaker control.

Connection settings also offers experimental direct video: a 320 × 480 screen stream, measured around 11–12 fps on our iPod touch 4. Veency still handles input. This is not a comparative performance guarantee. Leave it disabled for full-resolution Veency video.

These features need the device helpers and a jailbroken iPod with MobileSubstrate and SSH. Only iPod touch 4 on iOS 5.1.1 has been tested. Helpers listen on device loopback ports 5902/5903, reached through USB. The audio helper taps the output mixer in mediaserverd; it does not create a microphone capture session.

Download the helper ZIP from Releases and extract it, preserving its folders. With an SSH tunnel on local port 2222, run:

```sh
./Device/install.sh
```

The installer uses your existing SSH authentication and never stores a password. Set IPOD_SSH_HOST and IPOD_SSH_PORT for a different connection. Restart the iPod after first installation to load the audio hook. To remove only these helpers, run `./Device/uninstall.sh`, then restart. Neither script removes your apps or their data.

To build helpers from source, set IPOD_SDK to your local iPhoneOS 4.3 SDK and run `./Device/build.sh`; clang and ldid are required. The SDK is not redistributed.

## Downloads

[Releases](https://github.com/mannanshukla/ipod-mirror/releases) include the Apple Silicon Mac app and optional device helpers. This is an experimental, ad-hoc signed build, not notarized. The Mac app requires macOS 13 or later. It is independent of Apple and is not compatible with stock iPhone Mirroring.
