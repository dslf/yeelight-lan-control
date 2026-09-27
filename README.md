# Yeelight W3 White — LAN Control

A PowerShell tool to control **Yeelight W3 White** smart bulbs over the local network using the Yeelight LAN protocol (no cloud).

> Disclaimer: written with OpenCode in Zen mode. Just for fun.

## Features

- Discovers bulbs on the network: SSDP (multicast `239.255.255.250:1982`) plus a TCP scan of port `55443`.
- **Stable aliases**: each bulb is bound to its MAC address, so the alias survives IP changes (e.g. DHCP renewals).
- Power on/off/toggle and brightness control for a single bulb or an entire group.
- **Groups**: group bulbs together and command them all at once.
- State and settings are persisted in `config.json` next to the script.
- Commands are sent to group members **in parallel**, so a group acts almost instantly.

## Requirements

- **PowerShell 7+** (`pwsh`). Check: `pwsh -v`.
- A Windows machine on the same subnet as the bulbs (the LAN protocol does not cross VLANs or the internet).
- **"LAN Control"** (Управление по локальной сети) must be enabled for each bulb in the Mi Home / Yeelight app.
- Firewall: allow UDP multicast and outbound TCP connections to port `55443`.

## Quick start

```powershell
pwsh -ExecutionPolicy Bypass -File .\yeelight.ps1 scan
```

Or from the project folder:

```powershell
.\yeelight.ps1 scan
```

## Commands

### Discovery and listing

| Command | Description |
|---|---|
| `scan` | Scans the network, finds bulbs, updates their IPs in `config.json`. New bulbs get auto-aliases `bulb1`, `bulb2`, … |
| `list` | Shows saved bulbs and groups from `config.json`. |

`scan` parameters:

| Parameter | Description |
|---|---|
| `-Network 192.168.88` | Subnet prefix (defaults to the local IP's subnet). |
| `-Sweep` | Force a full TCP scan of all 254 addresses. |
| `-TimeoutMs 3000` | SSDP response wait time, ms. |

### Aliases

```powershell
.\yeelight.ps1 alias -Target 192.168.88.20 -Alias kitchen
.\yeelight.ps1 alias -Target kitchen -Alias living_room   # rename
```

Renaming a bulb automatically updates all group references.

### Control

The target (`-Target`) may be a bulb alias, an IP address, or a group name. If omitted, the command applies to **all** bulbs.

```powershell
.\yeelight.ps1 on                              # turn on everything
.\yeelight.ps1 off -Target kitchen             # turn off one bulb
.\yeelight.ps1 toggle -Target whole_floor      # toggle a group
.\yeelight.ps1 bright -Brightness 40 -Target living_room   # brightness 1–100
.\yeelight.ps1 status                          # status of all bulbs
.\yeelight.ps1 status -Target whole_floor
```

Parameters:

| Parameter | Description |
|---|---|
| `-Target` | Bulb alias, IP, or group name. Empty = all bulbs. |
| `-Brightness` | Brightness 1–100 for the `bright` command. |
| `-Rescan` | Re-scan the network before running the command (refresh IPs). |

### Groups

```powershell
# create a group
.\yeelight.ps1 group -GroupAction add -Group whole_floor -Members kitchen,living,bedroom

# add / remove a bulb
.\yeelight.ps1 group -GroupAction member-add -Group whole_floor -Members bathroom
.\yeelight.ps1 group -GroupAction member-remove -Group whole_floor -Members bathroom

# delete a group
.\yeelight.ps1 group -GroupAction remove -Group whole_floor

# show groups and the current state of their bulbs
.\yeelight.ps1 group -GroupAction show
```

Control a group with the regular commands and `-Target <group>`:

```powershell
.\yeelight.ps1 on -Target whole_floor
.\yeelight.ps1 off -Target whole_floor
```

`-Members` accepts aliases or IPs — aliases are what gets stored in the config.

## Configuration file `config.json`

Created automatically on the first `scan`. Can be edited manually:

```json
{
  "bulbs": [
    { "Mac": "b4-60-ed-1c-81-6e", "Alias": "kitchen",     "Ip": "192.168.88.20", "Port": 55443 },
    { "Mac": "b4-60-ed-61-dd-be", "Alias": "living_room", "Ip": "192.168.88.25", "Port": 55443 }
  ],
  "groups": {
    "whole_floor": ["kitchen", "living_room"]
  }
}
```

- `Mac` — the stable bulb identifier; the alias→bulb mapping is independent of the IP address.
- Refresh IPs anytime with `scan` — aliases and groups are preserved.

## Notes

- Some bulb firmware versions do not answer SSDP — in that case the TCP scan of port `55443` is used as a fallback.
- The config is saved as UTF-8 with BOM so non-ASCII aliases display correctly in Windows editors.
- Only power and brightness are supported: the W3 White model has neither color nor color-temperature control.