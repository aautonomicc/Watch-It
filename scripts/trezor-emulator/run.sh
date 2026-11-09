#!/usr/bin/env bash
# Device tests for W@tch's Trezor signer, against Trezor's own firmware
# emulator (the real firmware, built for the desktop) — no hardware.
#
#   scripts/trezor-emulator/run.sh            run the device tests
#   scripts/trezor-emulator/run.sh up         start + set up the emulator, leave it running
#   scripts/trezor-emulator/run.sh down       stop it
#
# First run downloads into $WATCHIT_TREZOR_EMU_HOME (default
# ~/.cache/watchit-trezor-emu): the emulator binary (sha256-pinned), two
# small libraries it links (Ubuntu packages, unpacked locally — nothing is
# installed system-wide) and a Python venv with trezorlib, which drives
# the emulator's screen through its debug link.
#
# The emulator runs as the systemd user unit `watchit-trezor-emu` and
# listens on UDP 21324 — trezor-client finds it exactly like a USB
# device. STOP IT before running the ordinary `cargo test`: those tests
# expect no device and would start talking to it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
export WATCHIT_TREZOR_EMU_HOME="${WATCHIT_TREZOR_EMU_HOME:-$HOME/.cache/watchit-trezor-emu}"
EMU_HOME="$WATCHIT_TREZOR_EMU_HOME"
VERSION=2.10.0
MODEL=T3T1   # Trezor Safe 5
BIN="trezor-emu-core-$MODEL-v$VERSION"
BIN_SHA256=21976088eead0f6b5acf2eb2c2c8eb08d52134e9d30dcb88a08011187c06124c
UNIT=watchit-trezor-emu
AUTOLOCK_SECS=10   # the firmware's minimum — the auto-lock tests wait it out

fetch() {
  mkdir -p "$EMU_HOME/bin" "$EMU_HOME/libs" "$EMU_HOME/debs" "$EMU_HOME/profile"
  if [ ! -x "$EMU_HOME/bin/$BIN" ]; then
    curl -fsSL -o "$EMU_HOME/bin/$BIN.part" \
      "https://data.trezor.io/dev/firmware/releases/emulators-new/$MODEL/$BIN"
    echo "$BIN_SHA256  $EMU_HOME/bin/$BIN.part" | sha256sum -c -
    mv "$EMU_HOME/bin/$BIN.part" "$EMU_HOME/bin/$BIN"
    chmod +x "$EMU_HOME/bin/$BIN"
  fi
  if ! find "$EMU_HOME/libs" -name 'libjpeg.so.62' | grep -q .; then
    (cd "$EMU_HOME/debs" && apt-get download libjpeg62 libsdl2-image-2.0-0 >/dev/null)
    for deb in "$EMU_HOME"/debs/*.deb; do dpkg -x "$deb" "$EMU_HOME/libs"; done
  fi
  if [ ! -x "$EMU_HOME/venv/bin/python" ]; then
    python3 -m venv "$EMU_HOME/venv"
    "$EMU_HOME/venv/bin/pip" install -q trezor==0.20.2
  fi
}

py() { "$EMU_HOME/venv/bin/python" -I "$HERE/$1" "${@:2}"; }

start() {
  fetch
  systemctl --user stop "$UNIT" 2>/dev/null || true
  # The released emulator is a Nix build: run it through the system
  # loader with the unpacked libraries on the path.
  systemd-run --user --quiet --unit="$UNIT" --collect \
    -E TREZOR_PROFILE_DIR="$EMU_HOME/profile" \
    -E SDL_VIDEODRIVER=dummy -E TREZOR_DISABLE_FADE=1 -E TREZOR_DISABLE_ANIMATION=1 \
    -E LD_LIBRARY_PATH="$EMU_HOME/libs/usr/lib/x86_64-linux-gnu" \
    -p WorkingDirectory="$EMU_HOME/bin" \
    -p StandardOutput="file:$EMU_HOME/emulator.log" -p StandardError="file:$EMU_HOME/emulator.log" \
    /lib64/ld-linux-x86-64.so.2 "$EMU_HOME/bin/$BIN" -O0 -X heapsize=20M -m main
}

stop() { systemctl --user stop "$UNIT" 2>/dev/null || true; }

up() {
  stop
  # A fresh device: one that still has a PIN from the last run would sit
  # at its boot screen, off the bus, until the PIN is entered there —
  # exactly like real hardware, and with nothing able to type it.
  rm -rf "$EMU_HOME/profile" && mkdir -p "$EMU_HOME/profile"
  start
  sleep 3
  py ctl.py setup "$AUTOLOCK_SECS"
}

case "${1:-test}" in
  up) up ;;
  down | stop) stop ;;      # "stop" doubles as unplugging the device
  start) start ;;           # …and "start" as plugging it back in (wallet kept)
  test)
    up
    trap stop EXIT
    cd "$REPO/native/watchit_core"
    PATH="$HOME/.cargo/bin:$PATH" cargo test --lib -- --ignored emu_ --test-threads=1 --nocapture "${@:2}"
    ;;
  *) sed -n 2,8p "$0"; exit 2 ;;
esac
