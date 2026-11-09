"""Play the human at the Trezor emulator: enter the PIN when the device
shows its PIN pad, confirm every screen. Every screen change is logged
with a timestamp so a test can be read back afterwards.

    operator.py <seconds> [options]

    --no-pin            never enter the PIN (leave the PIN pad waiting)
    --pin-after=N       wait N seconds at the PIN pad before entering it
    --hold-first=N      leave the FIRST confirmation screen untouched for
                        N seconds (so the device auto-locks under it);
                        when that screen comes back it is confirmed
    --refuse-first      press Cancel on the first confirmation screen

Survives the emulator being stopped and started (the "unplugged" tests):
it reconnects and carries on.
"""
import sys
import time

from trezorlib import models
from trezorlib.debuglink import DebugLink
from trezorlib.transport.udp import UdpTransport

PIN = "1234"
PASSPHRASE = "hunter2"
CONFIRMABLE = ("Frame", "Paragraphs", "SwipeUpScreen", "PromptScreen", "Dialog",
               "SwipePage", "HoldToConfirm", "VerticalMenu")


def opt(name: str, default: float) -> float:
    for a in sys.argv[2:]:
        if a.startswith(f"--{name}="):
            return float(a.split("=", 1)[1])
    return default


def connect() -> DebugLink:
    link = DebugLink(UdpTransport("127.0.0.1:21324").find_debug())
    link.model = models.T3T1
    link.version = (2, 10, 0)
    return link


def main() -> None:
    secs = float(sys.argv[1])
    no_pin = "--no-pin" in sys.argv
    refuse_first = "--refuse-first" in sys.argv
    pin_after = opt("pin-after", 0)
    hold_first = opt("hold-first", 0)

    t0 = time.time()

    def log(msg: str) -> None:
        print(f"{time.time() - t0:6.1f}s {msg}", flush=True)

    d = None
    last = None
    since = 0.0          # when the current screen appeared
    held = None          # the screen --hold-first is (or was) holding
    hold_from = 0.0
    refused = False

    while time.time() - t0 < secs:
        time.sleep(0.25)
        try:
            if d is None:
                d = connect()
            lc = d.read_layout(wait=False)
            key = (lc.main_component(), lc.title(), lc.text_content()[:100])
        except Exception as e:  # the emulator is down ("unplugged")
            key = ("(no device)", type(e).__name__, "")
            try:
                if d is not None:
                    d.close()
            except Exception:
                pass
            d = None
        now = time.time()
        if key != last:
            log(str(key))
            last = key
            since = now
        if d is None:
            continue
        main_c, title, text = key
        try:
            if main_c == "PinKeyboard":
                if not no_pin and now - since >= pin_after:
                    d.input(PIN)
                    log("-> entered the PIN")
                    last = None
            elif main_c == "PassphraseKeyboard":
                # Passphrase entry on the device (the app's default).
                d.input(PASSPHRASE)
                log("-> typed the passphrase on the device")
                last = None
            elif main_c in CONFIRMABLE and "enter your passphrase" not in text:
                if hold_first and held is None:
                    held, hold_from = key, now
                    log(f"-> holding {title!r} for {hold_first:.0f}s")
                if held == key and now - hold_from < hold_first:
                    pass  # leave it waiting
                elif refuse_first and not refused:
                    d.press_no()
                    refused = True
                    log(f"-> pressed Cancel on {title!r}")
                    last = None
                else:
                    d.press_yes()
                    log(f"-> confirmed {title!r}")
                    last = None
        except Exception as e:
            log(f"(action failed: {type(e).__name__})")
            last = None


main()
