# iPod Mirror

A native macOS USB viewer for a jailbroken iPod running Veency. This is an early prototype, not Apple's iPhone Mirroring service.

## Run

Open `build/iPod Mirror.app`. Plug in the iPod, enable Veency in its Settings, unlock the screen, select its USB identifier, and click Connect. Accept Veency's access request on the iPod if shown. If Veency has a password, enter it in the Mac app. The password is kept in memory only.

- Click to tap; drag to swipe.
- Click the screen, then type. Return, Backspace, Tab, Escape and arrow keys are supported. Unicode text depends on the device's Veency build; IME composition is not implemented.
- Home (Command-H) and Lock (Command-L) use Veency's documented mouse button mappings.
- Save a full-resolution PNG with Screenshot (Command-S).
- Disconnect stops the USB session. After an established connection drops, the viewer retries the same device until Stop is pressed. Initial connection/authentication failures require another Connect.

The USB device picker currently shows the last eight characters of each device identifier, not a friendly device name. Choose the iPod if multiple devices are attached. Modern stock iPhones cannot run this backend.

## Build and test

Requires macOS 13+ and Apple's Command Line Tools. The build targets the Mac architecture it is built on; this first build is Apple Silicon. No Xcode project, Homebrew dependencies, iproxy process, or network service is needed.

```sh
./build.sh
./test.sh
```

The app is locally ad-hoc signed, not notarized for public distribution. Protocol tests exercise RFB 3.3/3.8, authentication, partial frames, input packet encoding, resizing, invalid rectangles, and cancellation using local socket pairs. The DES response fixture is independently checked with OpenSSL using the VNC bit-reversed password key.

## Architecture and privacy

`Transport.swift` speaks plist usbmux to `/var/run/usbmuxd`, enumerates USB devices, and asks it to connect to the selected device's port 5900. `RFB.swift` implements RFB/VNC with raw rectangles and display resizing. `App.swift` supplies the AppKit window and input mapping.

Connection states are idle → connecting → connected → waiting (after a drop). A session generation rejects callbacks from old connections. Disconnect shuts down the socket to unblock pending reads; the owning Wire closes its descriptor on deallocation. Frame delivery coalesces to one pending frame on the main thread. Input writes run on a separate serial queue. Weak callbacks avoid retaining a session through its own frame handler.

The app does not install or change anything on the iPod. It does not read app databases, sync files, transmit telemetry, or share the clipboard. Screenshots are written only when requested. VNC's legacy password scheme is not modern encryption; this client connects only through the local USB service and does not open a network listener. Veency itself may also listen on the iPod's Wi-Fi interface; this app does not change that setting.

## Prototype limits

- Live 640 × 960 screen, taps, Home, swipe-to-Spotlight, and Mac keyboard input verified on iPod touch 4 / iOS 5.1.1. Disconnect and reconnect also verified after accepting Veency’s device-side access prompt. Automatic recovery after a physical cable unplug has not yet been tested.
- Veency remains required. It may need the iPod awake and an access prompt accepted.
- Raw screen updates favor compatibility over compression; actual frame rate depends on the iPod and Veency.
- No audio, notification forwarding, clipboard sync, multitouch, or screen-off mirroring.
- No claim of memory-leak-free operation; protocol cancellation and closure ownership are checked, but Instruments testing remains pending.

## References

- [RFB protocol, RFC 6143](https://www.rfc-editor.org/rfc/rfc6143)
- [Veency controls and setup](https://cydia.saurik.com/info/veency/)
- [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) for the USB service protocol
