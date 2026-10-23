# Claude CoastClear

A macOS menu bar tool that checks whether your network exit matches your system and browser environment, and rates the environment risk for running Claude. The app and command are named `cc`, short for CoastClear.

[简体中文](README.md) · [Changelog (Chinese)](CHANGELOG.md) · [Differences from the original project (Chinese)](docs/upstream-differences.md)

## Features

- Three-route exit IP consistency check, with a line quality chart.
- Exit country, IP type and multi-source IP intelligence, DNS resolution, and IPv6 and WebRTC leak checks.
- Whether system and browser timezone, region and language match the exit.
- A 26-signal weighted score with risk levels, plus a full report in the browser.
- One-click repair for timezone, DNS, PAC and region format.

## Improvements over the original project

Claude CoastClear focuses on checking the Claude environment and improves on the original project as follows:

- **Focused on Claude environment checks**: removes the original project's redundant feature that changed the Codex configuration and ran a local proxy automatically at startup. cc no longer changes other apps' settings.
- **Checks never change system settings**: startup, scheduled checks and quitting are read-only; the timezone no longer follows the exit automatically and is only suggested.
- **Repairs need confirmation first**: every repair must be confirmed, and administrator authorization is requested only after that; no root daemon and no passwordless sudo. The confirmation dialog shows the results of the last check, so if you have switched proxy nodes since then, run "Re-check" manually before repairing.
- **More reliable results**: the current round is shown separately from history, and failed checks no longer reuse old data as if they succeeded; a temporarily failed score is re-checked once automatically.
- **More complete checks**: fixes the IPv6 leak check, which never actually ran in the original project, and shows where the address comes from.

## Requirements

- macOS 12 or later, Apple silicon or Intel.
- Xcode Command Line Tools for building: `xcode-select --install`.
- Checks run through curl, which does not read the system HTTP proxy settings.
- The app is not signed or notarized. If macOS blocks it on first launch, choose "Open Anyway" in System Settings → Privacy & Security.

## Usage

```bash
bash menubar/build.sh            # Build menubar/cc.app
open menubar/cc.app              # Launch the menu bar app
bash cc-check.sh                 # Full check from the command line, no repairs
bash cc-check.sh --fix           # Check, then confirm and repair
bash install.sh                  # Install to /Applications without launching or adding a login item
bash install.sh --autostart      # Install and register a login item
bash uninstall.sh                # Remove the login item and delete the app after confirmation
```

## Network access and privacy

- Checks contact public IP lookup and connectivity services: ipip.net, ipify, icanhazip, ifconfig.me, ipinfo, ipapi.co, ipwho.is, ip-api (plain HTTP), ip.sb, myip.com, Cloudflare, Google and Anthropic. Browser checks also connect to Cloudflare and Google STUN servers.
- A lightweight exit check runs every minute by default; the full check runs when the exit changes or when you start it.
- Results are stored only in `~/Library/Application Support/cc` (override with `CC_DATA_DIR`). The browser report is passed through a token-protected `127.0.0.1` local endpoint and is never uploaded.

## Notes

- Suited to people who travel across regions often and want to check their current network and device environment at any time.
- The score is a heuristic. It is not an official decision by any service provider and does not guarantee account safety.
- This project is not affiliated with Anthropic. Follow local laws and the terms of the services you use.

## Tests

```bash
bash test-cc-consent.sh && bash test-cc-check.sh && bash test-cc-network.sh && bash test-browser-report.sh
```

## License

Developed independently from the original project's 4.18 source under the MIT license, with the original copyright notice retained. See [LICENSE](LICENSE).
