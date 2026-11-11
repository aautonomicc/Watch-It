# Trezor device tests, without a Trezor

`run.sh` runs W@tch's own Trezor signer (`native/watchit_core/src/trezor.rs`)
against **Trezor's firmware emulator** — the real firmware, built for the
desktop — with a script playing the human at the device. It covers what a
fake transport cannot: what the firmware actually does when it is locked,
locks itself while a confirmation is waiting, or restarts.

```bash
scripts/trezor-emulator/run.sh          # set up + run the eight emu_* tests (~1 min)
scripts/trezor-emulator/run.sh up       # leave the emulator running (to drive the app by hand)
scripts/trezor-emulator/run.sh down
```

First run downloads into `~/.cache/watchit-trezor-emu` (override with
`WATCHIT_TREZOR_EMU_HOME`): the emulator binary (Safe 5, firmware 2.10.0,
sha256-pinned), two libraries it links (Ubuntu packages unpacked locally,
nothing installed system-wide) and a Python venv with `trezorlib`.

- The device is set up with the public Hardhat test mnemonic, PIN `1234`,
  passphrase protection on, and a 10-second auto-lock. With the passphrase
  `hunter2` its address is `0x55585EFaaFc6F444A28Dce28322edf57620c88Bf`.
- `operator.py` enters the PIN, types the passphrase and confirms screens
  through the emulator's debug link; `--hold-first=N` leaves a confirmation
  untouched so the device auto-locks under it, `--refuse-first` presses
  Cancel. `ctl.py` sets the device up, locks it, prints its screen.
- trezor-client finds the emulator on UDP 21324 exactly like a USB device,
  so the **app itself** can be driven against it too: `run.sh up`, launch the
  app, set the wallet up with `operator.py 60` running.

**Stop the emulator before the ordinary `cargo test`** — those tests expect
no device and would start talking to it (and hang at its PIN pad).

A PIN-protected device that is restarted sits at its boot screen, off the
bus, until the PIN is entered there — the debug link cannot reach that
screen, which is why `run.sh up` starts from a wiped profile and the
restart test uses a device without a PIN.
