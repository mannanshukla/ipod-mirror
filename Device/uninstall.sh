#!/bin/bash
set -euo pipefail
DEST="${IPOD_SSH_HOST:-root@127.0.0.1}"; PORT="${IPOD_SSH_PORT:-2222}"
SSH=(ssh -p "$PORT"); if [[ -n "${IPOD_SSH_CONTROL:-}" ]]; then SSH+=(-S "$IPOD_SSH_CONTROL"); fi
"${SSH[@]}" "$DEST" 'launchctl unload /Library/LaunchDaemons/dev.mannan.ipodmirror.screen.plist >/dev/null 2>&1; rm -f /Library/LaunchDaemons/dev.mannan.ipodmirror.screen.plist /usr/local/libexec/ipod-mirror-screen /Library/MobileSubstrate/DynamicLibraries/iPodMirrorAudio.dylib /Library/MobileSubstrate/DynamicLibraries/iPodMirrorAudio.plist'
echo 'Helpers removed. Restart the iPod to unload the audio hook. App data is not changed.'
