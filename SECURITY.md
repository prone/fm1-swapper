# Security

This app writes firmware and settings to hardware, so please report security problems privately rather than in a
public issue: use GitHub's "Report a vulnerability" (Security tab) on this repository.

Useful details: what an attacker controls (a firmware or backup file, a device on the network or Bluetooth, the
emulator web page), what happens, and the steps to reproduce.

Areas with an attack surface: firmware and backup imports, the check-in server (`tools/checkin_server.py`, local
network), the emulator web view bridge, and the SMC-PAD Bluetooth light session.
