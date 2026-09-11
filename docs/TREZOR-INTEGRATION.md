# Trezor Suite integration

W@tch has two wallet responsibilities:

- the embedded ANT upload client needs a signer for storage payments and gas;
- the user may keep long-lived funds on a hardware wallet.

The desktop app must not copy a seed phrase or private key into either path.

## Current slice

Settings → Wallet can connect to the local Trezor Suite MCP server at
`http://127.0.0.1:21340/mcp`. The user pastes the token shown by Trezor Suite's
Experimental Features → MCP Server panel. The token is held in memory only.

The app initializes the MCP session and reads the default EVM address at
`m/44'/60'/0'/0/0`. The user can request a second address read with
`showOnTrezor: true` and compare it on the device. No transaction, signature,
broadcast, or ANT payment happens in this slice.

## Upload handoff

The existing `watchit_core` upload manager owns an `ant_core::data::Wallet`
with a private key. A hardware-backed upload mode needs a native signer boundary
inside that manager. The next implementation must:

1. confirm the Autonomi ANT network and chain ID used by the running core;
2. expose the prepared upload and exact payment calldata through a short-lived,
   authenticated native job;
3. show the amount, recipient, network and purpose in W@tch;
4. ask Trezor Suite to send the approval/payment transaction through its MCP tool;
5. require physical confirmation on the Trezor;
6. return transaction hashes to the native finalize path without persisting keys;
7. leave the current hot-wallet mode available as an explicit fallback.

Until that boundary exists, the Trezor card is intentionally labelled
read-only. A connected address must never silently replace the upload wallet.
