# Free DynDNS Cloudflare

**EasyDynDNS** is a tiny macOS menu bar app that keeps **every public IP you have recently used** published under a single DNS name, for free, using your own Cloudflare zone.

It is built for one job: letting you reach servers that only accept SSH (or anything else) from an allowlist, while you move between home, office, coworking and tethering. Point the firewall rule at `home.example.com`, and EasyDynDNS keeps that name pointed at all of your active IPs.

- Green icon: enabled and last sync succeeded. Red icon: paused or something is wrong (the menu tells you what).
- Native Swift, no dependencies, about 20 MB of memory, idle almost all the time.
- Your Cloudflare token stays in the macOS Keychain. Nothing is sent anywhere except Cloudflare.

## How it works

Classic dynamic DNS replaces the old IP with the new one. That breaks allowlists as soon as you have two networks in play (a laptop and a home server, two Macs, a VPN that flaps). EasyDynDNS **adds** instead of replacing:

1. It detects your public IPv4 and IPv6 (Cloudflare's `cdn-cgi/trace`, with ipify as a fallback).
2. It lists the `A` / `AAAA` records of your DNS name through the Cloudflare API.
3. If your current IP is missing, it creates a record for it. If it is there, it refreshes its "last seen" time.
4. The "last seen" time is stored in the Cloudflare record comment, for example `dyndns last-seen=2026-01-01T12:00:00Z host=my-laptop`. Several Macs can share the same name, and the state survives a reinstall.
5. A record that has shown no sign of life for longer than the retention period (12 hours by default) is deleted.

Safety rules:

- Records without the `dyndns` marker in their comment (the ones you created by hand) are **never** modified or deleted.
- If the public IP cannot be determined (offline, captive portal), nothing is changed and nothing is deleted.
- The last remaining record of the name is never deleted.
- The comment is only rewritten when it is older than 15 minutes, to keep API calls low.

A sync runs every 5 minutes, right after any network change, and after the Mac wakes up.

## Requirements

- macOS 13 Ventura or later (Apple silicon or Intel)
- A domain whose DNS is hosted on Cloudflare (the free plan is fine)

## Installation

### 1. Get the app

Download the latest notarized `EasyDynDNS-x.y.z.zip` from the [Releases](../../releases) page, unzip it and move `EasyDynDNS.app` to `/Applications`.

Or build it from source (Xcode or the Command Line Tools required):

```bash
git clone https://github.com/jrlprost/easydyndns.git
cd easydyndns
scripts/build.sh
cp -R build/EasyDynDNS.app /Applications/
```

### 2. Create a Cloudflare API token

In the Cloudflare dashboard, go to **My Profile > API Tokens > Create Token > Create Custom Token**:

| Setting | Value |
|---|---|
| Permissions | `Zone` / `DNS` / `Edit` |
| Zone Resources | `Include` / `Specific zone` / your domain |

That is the only permission needed. Optionally restrict **Client IP Address Filtering** and set an expiry date.

Also copy your **Zone ID**: open your domain in the dashboard, it is in the **API** box of the Overview page (right column).

### 3. Configure

```bash
mkdir -p ~/.config/easydyndns
cp config.example ~/.config/easydyndns/config   # or let the app create it
open -e ~/.config/easydyndns/config
```

Set at least `zone_id` and `record_name`:

```ini
zone_id = 0123456789abcdef0123456789abcdef
record_name = home.example.com
retention = 12h
interval = 5m
```

The record name does not need to exist yet: EasyDynDNS creates it.

### 4. Install

```bash
/Applications/EasyDynDNS.app/Contents/MacOS/EasyDynDNS install
```

This checks the config, asks for the token (typed input is hidden), verifies it against Cloudflare, stores it in the Keychain, enables launch at login and starts the menu bar app.

You can also just open the app and use **Set Cloudflare token…** and **Open configuration** from its menu.

## Usage

### Menu bar

| Item | What it does |
|---|---|
| Status line | Active, paused, or the last error |
| Sync now | Runs a sync immediately |
| Enabled | Pauses or resumes automatic syncing |
| Launch at login | Starts EasyDynDNS when you log in |
| Set Cloudflare token… | Stores or replaces the token in the Keychain |
| Open configuration / Open log | Opens the config file or the log |

A notification is shown when an IP is added or removed, and after 3 failed syncs in a row.

### Command line

The app binary doubles as a CLI. An alias helps:

```bash
alias easydyndns=/Applications/EasyDynDNS.app/Contents/MacOS/EasyDynDNS
```

| Command | Description |
|---|---|
| `easydyndns status` | Published IPs with their last-seen and age |
| `easydyndns dry-run` | What would be added, refreshed or deleted, without writing anything |
| `easydyndns run` | One sync now |
| `easydyndns set-token` | Store or replace the token |
| `easydyndns install` | Set everything up (see above) |
| `easydyndns uninstall` | Disable launch at login, quit the app, delete the token |

Example:

```text
$ easydyndns status
home.example.com
TYPE IP                                       LAST SEEN (UTC)       AGE     HOST
A    203.0.113.7                              2026-01-01T12:05:00Z  2m      my-laptop  <- this network
AAAA 2001:db8:1234::1                         2026-01-01T12:05:00Z  2m      my-laptop  <- this network
A    198.51.100.23                            2026-01-01T08:40:00Z  3h27    my-laptop
```

### Using it with a firewall allowlist

Most allowlists (cloud security groups, `ufw`, `nftables`) do not resolve DNS names on their own. A common pattern is a small cron job on the server that resolves the name and refreshes the rule. For example, with `ufw`:

```bash
#!/bin/bash
# /usr/local/bin/allow-dyndns.sh, run every 5 minutes from cron
NAME=home.example.com
for ip in $(dig +short A "$NAME") $(dig +short AAAA "$NAME"); do
  ufw allow from "$ip" to any port 22 proto tcp comment "dyndns" >/dev/null
done
```

Remember to also remove rules for IPs that disappeared from the name; tools like `ferm` or `nftables` sets make this easier.

## Files

| Path | Content |
|---|---|
| `~/.config/easydyndns/config` | Your configuration (keep it out of git) |
| `~/Library/Logs/EasyDynDNS/easydyndns.log` | One line per add, refresh, delete, error and sync |
| Keychain item `EasyDynDNS` | The Cloudflare API token |

## Uninstall

```bash
/Applications/EasyDynDNS.app/Contents/MacOS/EasyDynDNS uninstall
rm -r /Applications/EasyDynDNS.app ~/.config/easydyndns ~/Library/Logs/EasyDynDNS
```

DNS records are left in place; delete them from the Cloudflare dashboard if you no longer need them.

## Security

- The token is stored only in the login Keychain. It is never written to a file, a log or the console, and the authorization header is never logged.
- Use a token limited to `Zone > DNS > Edit` on a single zone. If it leaks, the worst case is DNS changes on that one zone: revoke it from the Cloudflare dashboard.
- Publishing your IPs in public DNS reveals them to anyone who looks the name up. Pick a name that is not easy to guess if that matters to you.
- Found a vulnerability? Please open a private security advisory on GitHub rather than a public issue.

## Development

```bash
swift test          # unit tests for the decision logic
scripts/build.sh    # ad-hoc signed build in build/EasyDynDNS.app
VERSION=1.0.0 scripts/release.sh   # Developer ID signing + notarization (see the script header)
```

The code is split into `EasyDynDNSCore` (config, Cloudflare client, IP detection, sync planning) and `EasyDynDNS` (menu bar app and CLI).

## License

MIT, see [LICENSE](LICENSE).
