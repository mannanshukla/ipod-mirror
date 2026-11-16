# Optional USB helpers

Both listeners bind only to device loopback. They do not advertise on Wi-Fi. The Mac reaches them through usbmux. These experimental helpers do not implement authentication beyond local-device/USB access; do not forward their ports to a network. Veency's own network behavior is separate.

## Audio: port 5903

Client and server exchange ASCII `IMA1`. Server packets contain four big-endian UInt32 values: sample rate, channel count, frame count, payload bytes. The payload is interleaved little-endian float32 PCM. Supported: 8–96 kHz, 1–2 channels, 1–2048 frames, exactly frames × channels × 4 payload bytes.

The mediaserverd Substrate hook observes successfully rendered `mcmx` output. It opens no microphone or input AudioSession. The real-time thread uses a fixed ring and try-lock; it never performs socket IO or allocates a packet. A background thread transmits. Ring overflow drops a packet instead of blocking system playback. Only a connected client enables copying. TCP_NODELAY avoids delayed small audio packets.

Mac playback starts after four packets, queues at most twelve and reprimes after a drain. No timestamp-based A/V sync yet. The audio still plays on the iPod; mute on the Mac is independent. Mixing multiple simultaneous sources and long-session clock drift need more testing.

## Direct video: port 5902

Client sends ASCII `FRAM`. Each response has five big-endian UInt32 values: magic `IMV1`, width, height, payload bytes, capture/scaling microseconds. Payload is 320 × 480 RGBX. Each request captures a fresh frame; there is no video backlog. The helper sleeps in accept/recv while unused.

Tested on iPod touch 4 / iOS 5.1.1: ~11–12 fps over USB in short 60-frame runs. This is not a comparative Veency benchmark or a guaranteed sustained rate. The image is lower resolution than Veency. Input still goes through Veency with coordinates scaled to its framebuffer. Portrait only; orientation handling and screen-off capture remain unfinished.

## Multitouch: port 5904

Served by `iPodMirrorTouch.dylib` inside SpringBoard. Client sends ASCII `IMT1`. Server replies with 12 bytes: `IMT1`, screen width and height in portrait pixels (UInt16 big-endian; 640 × 960 on iPod touch 4), maximum fingers (5), and three zero bytes.

Each client frame is a 4-byte header, `T`, phase, finger count (1–5), zero, followed by one big-endian UInt16 x and y per finger in portrait screen pixels. Phases: 1 began, 2 moved, 3 ended, 4 cancelled. The server sends nothing after the handshake.

A frame becomes one GraphicsServices hand event with one path per finger, as Veency does for its single touch. The window under the first finger at `began` receives every event of that gesture, even if the fingers move over another window. A `began` while fingers are down cancels the old gesture first. Moves and ends are ignored unless a gesture is open with the same finger count. Any malformed header closes the connection, including a nonzero reserved byte. Once a frame's first byte arrives, the rest must arrive within 2 seconds.

No touch stays stuck. The server cancels held fingers when the connection closes, when no frame arrives for about 3 seconds while fingers are down, or when a frame stalls part-way. A new connection replaces the old one, which is closed and has its fingers cancelled. Only the newest accepted connection may begin or drive a gesture; frames an older connection had already read are dropped. Only the connection that began the gesture can move or end it, and injection is serialized. The window is hit-tested in screen pixels, as Veency does. While fingers are held still, the Mac repeats the current position once a second.

The Mac connects at the start of the first two-finger gesture, not at session start, and waits five seconds after a failed connection before trying again. It sends nothing for a gesture whose `began` did not reach the iPod.

## Measurements

The first screenshot+CoreGraphics scaling attempt reached 6.5 fps. Sampling native BGRA pixels directly improved the measured rate to 12.2 fps in that run. A later run measured 11.6 fps. Capture-only was ~30 ms/frame, excluding pixel extraction, scaling and transport.

Initial Mac audio was audibly choppy. TCP_NODELAY plus startup/rebuffer handling fixed the user's music test; the app reported zero rebuffers and the user confirmed normal smooth sound. This verifies that session, not all apps/sample formats or hours-long stability.
