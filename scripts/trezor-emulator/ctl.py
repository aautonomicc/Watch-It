"""One-shot control of the Trezor emulator for the W@tch device tests.

    ctl.py setup [autolock_secs] [nopin]
                                   wipe, load the test wallet (PIN 1234
                                   unless "nopin", passphrase protection
                                   on), set the auto-lock delay
    ctl.py lock                    lock the device now
    ctl.py layout                  print what the device screen shows

The wallet is the well-known Hardhat test mnemonic — never a real one.
With the passphrase "hunter2" its first Ethereum address is
0x55585EFaaFc6F444A28Dce28322edf57620c88Bf (what the Rust tests expect).
"""
import json
import sys

from trezorlib import device, models
from trezorlib.debuglink import DebugLink, TrezorTestContext, load_device
from trezorlib.transport.udp import UdpTransport

MNEMONIC = "test test test test test test test test test test test junk"
PIN = "1234"
WIRE = "127.0.0.1:21324"


def main() -> None:
    cmd = sys.argv[1]
    if cmd == "setup":
        autolock = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        pin = None if "nopin" in sys.argv else PIN
        ctx = TrezorTestContext(UdpTransport(WIRE), force_wipe=True)
        if ctx.features.initialized:
            ctx.wipe_device()
        session = ctx.get_seedless_session()
        load_device(session, MNEMONIC, pin=pin, passphrase_protection=True, label="watch-emu")
        if pin:
            device.apply_settings(session, auto_lock_delay_ms=autolock * 1000)
        f = ctx.refresh_features()
        print(f"ready: pin={f.pin_protection} passphrase={f.passphrase_protection} "
              f"autolock_ms={f.auto_lock_delay_ms}")
    elif cmd == "lock":
        try:
            ctx = TrezorTestContext(UdpTransport(WIRE))
            ctx.lock()
        except Exception as e:  # already locked reads as an error here
            print(f"lock: {type(e).__name__}")
        else:
            print("locked")
    elif cmd == "layout":
        d = DebugLink(UdpTransport(WIRE).find_debug())
        d.model = models.T3T1
        d.version = (2, 10, 0)
        lc = d.read_layout(wait=False)
        print(json.dumps({"main": lc.main_component(), "title": lc.title(),
                          "text": lc.text_content()[:200]}))
        d.close()
    else:
        sys.exit(__doc__)


main()
