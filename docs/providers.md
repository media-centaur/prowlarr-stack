# VPN providers

The stack uses [gluetun](https://github.com/qdm12/gluetun) as its VPN gateway, which supports 40+ providers via WireGuard. The installer has built-in hints for seven popular ones; any other gluetun-supported WireGuard provider also works — you'll just type its gluetun slug at the installer's provider prompt and supply whatever credentials that provider needs.

## Provider summary

| Provider   | Extra credentials needed                          | Port forwarding         | Where to get the key                                                 |
| ---------- | ------------------------------------------------- | ----------------------- | -------------------------------------------------------------------- |
| NordVPN    | (none)                                            | No                      | Linux CLI extraction (see below)                                     |
| ProtonVPN  | (none)                                            | Paid plans (opt-in)     | `account.protonvpn.com` → Downloads → WireGuard config               |
| Mullvad    | `WIREGUARD_ADDRESSES`                             | No (removed 2023)       | `mullvad.net` → Account → WireGuard                                  |
| Surfshark  | `WIREGUARD_ADDRESSES`                             | No                      | `my.surfshark.com` → VPN → Manual setup → WireGuard                  |
| IVPN       | `WIREGUARD_ADDRESSES`                             | No                      | `ivpn.net` → Account → WireGuard key generation                      |
| AirVPN     | `WIREGUARD_ADDRESSES` + `WIREGUARD_PRESHARED_KEY` | Yes                     | `airvpn.org` → Client Area → Config Generator                        |
| Windscribe | `WIREGUARD_ADDRESSES` + `WIREGUARD_PRESHARED_KEY` | Paid plans (opt-in)     | `windscribe.com` → My Account → Config Generators → WireGuard        |
| Any other  | varies                                            | check provider's docs   | See [gluetun's provider wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers) |

If you plan to opt qBittorrent into the VPN tunnel (`QBITTORRENT_USE_VPN=1`) and care about seeding, pick a provider that forwards ports. Otherwise peer connectivity is outbound-only and tracker stats stay near zero. Provider PF policies change — verify with your provider's current docs before you subscribe.

All WireGuard private keys are 44 characters of base64, regardless of provider. The installer validates that format before accepting the key.

## Extracting your WireGuard credentials

### NordVPN

NordVPN doesn't display WireGuard keys in its web dashboard; you extract one from the Linux CLI.

**Install prerequisites:**

```sh
# wireguard-tools (provides the `wg` command)
pacman -S wireguard-tools          # Arch
apt install wireguard-tools        # Debian/Ubuntu

# NordVPN Linux CLI — install per https://nordvpn.com/download/linux/
```

**Extract your key (one-time per host):**

```sh
nordvpn login                           # browser login
nordvpn set technology NordLynx
nordvpn connect                         # brings up the wg interface
sudo wg show nordlynx private-key       # copy the 44-character base64 output
nordvpn disconnect                      # optional — takes your desktop off the VPN again
```

Paste that key into the installer when prompted.

**Credentials the installer will ask for:** `WIREGUARD_PRIVATE_KEY`, `SERVER_COUNTRIES`.

More detail: [gluetun NordVPN docs](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/nordvpn.md).

### ProtonVPN

Log in at [account.protonvpn.com](https://account.protonvpn.com), go to **Downloads → WireGuard configuration**, generate a Linux config, and copy the `PrivateKey` value from the `[Interface]` section.

**Credentials the installer will ask for:** `WIREGUARD_PRIVATE_KEY`, `SERVER_COUNTRIES`.

### Mullvad

Log in at [mullvad.net/en/account/wireguard](https://mullvad.net/en/account/wireguard), generate a WireGuard key, download the config, and copy both `PrivateKey` and `Address` from the `[Interface]` section.

**Credentials the installer will ask for:** `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `SERVER_COUNTRIES`.

### Surfshark

Log in at [my.surfshark.com](https://my.surfshark.com), go to **VPN → Manual setup → WireGuard**, generate credentials, download the config, and copy `PrivateKey` and `Address` from the `[Interface]` section.

**Credentials the installer will ask for:** `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `SERVER_COUNTRIES`.

### IVPN

Log in at [ivpn.net/account](https://www.ivpn.net/account), go to **WireGuard key generation**, generate a keypair, and copy `PrivateKey` and `Address` from the generated config.

**Credentials the installer will ask for:** `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `SERVER_COUNTRIES`.

### AirVPN

Log in at [airvpn.org](https://airvpn.org), go to **Client Area → Config Generator**, select WireGuard and your target server, generate the config, and copy `PrivateKey`, `Address`, and `PresharedKey` from the file.

**Credentials the installer will ask for:** `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `WIREGUARD_PRESHARED_KEY`, `SERVER_COUNTRIES`.

### Windscribe

Log in at [windscribe.com](https://windscribe.com), go to **My Account → Config Generators → WireGuard**, generate a config, and copy `PrivateKey`, `Address`, and `PresharedKey` from the `[Interface]` section.

**Credentials the installer will ask for:** `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `WIREGUARD_PRESHARED_KEY`, `SERVER_COUNTRIES`.

### An unlisted provider

If your provider isn't in the table above but is [supported by gluetun](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers), type its gluetun slug at the installer's provider prompt. The installer will ask for `WIREGUARD_ADDRESSES` and `WIREGUARD_PRESHARED_KEY` — leave either blank if your provider's gluetun page doesn't list it as required. Gluetun will reject a genuinely-unknown slug at startup with a clear error.

## Rotating credentials

Generate a new WireGuard key at your provider's site whenever you want, then:

```sh
./setup --reconfigure
./scripts/restart
./check
```

Your existing values appear as defaults at each prompt — hit Enter to keep or type to change.
