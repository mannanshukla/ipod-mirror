#!/bin/bash
# Uses an existing SSH connection. No credentials are stored in this project.
set -euo pipefail
cd "$(dirname "$0")"
DEST="${IPOD_SSH_HOST:-root@127.0.0.1}"
PORT="${IPOD_SSH_PORT:-2222}"
SSH=(ssh -p "$PORT")
if [[ -n "${IPOD_SSH_CONTROL:-}" ]]; then SSH+=(-S "$IPOD_SSH_CONTROL"); fi
command_remote() { "${SSH[@]}" "$DEST" "$1"; }
for file in ../build/device/iPodMirrorAudio.dylib ../build/device/ipod-mirror-screen; do
 [[ -f "$file" ]] || { echo 'Build the helpers with Device/build.sh first.'; exit 1; }
done
command_remote 'mkdir -p /usr/local/libexec'
command_remote 'cat > /usr/local/libexec/ipod-mirror-screen.new && chmod 755 /usr/local/libexec/ipod-mirror-screen.new && mv /usr/local/libexec/ipod-mirror-screen.new /usr/local/libexec/ipod-mirror-screen' < ../build/device/ipod-mirror-screen
command_remote 'cat > /Library/MobileSubstrate/DynamicLibraries/iPodMirrorAudio.dylib.new && chmod 755 /Library/MobileSubstrate/DynamicLibraries/iPodMirrorAudio.dylib.new && mv /Library/MobileSubstrate/DynamicLibraries/iPodMirrorAudio.dylib.new /Library/MobileSubstrate/DynamicLibraries/iPodMirrorAudio.dylib' < ../build/device/iPodMirrorAudio.dylib
command_remote 'cat > /Library/MobileSubstrate/DynamicLibraries/iPodMirrorAudio.plist' < iPodMirrorAudio.plist
command_remote 'cat > /Library/LaunchDaemons/dev.mannan.ipodmirror.screen.plist && chmod 644 /Library/LaunchDaemons/dev.mannan.ipodmirror.screen.plist' < dev.mannan.ipodmirror.screen.plist
command_remote 'launchctl unload /Library/LaunchDaemons/dev.mannan.ipodmirror.screen.plist >/dev/null 2>&1; launchctl load /Library/LaunchDaemons/dev.mannan.ipodmirror.screen.plist'
echo 'Helpers installed. Restart the iPod to load the audio hook. App data is not changed.'
