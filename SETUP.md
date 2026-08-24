# Setup: getting your mesh keys

Everything hard about this plugin happens once, here. Budget twenty minutes the
first time.

## What this assumes

Before you start, these all need to be true. If one is not, jump to
[When an assumption does not hold](#when-an-assumption-does-not-hold).

1. **Your lights are Sidus Mesh fixtures.** Every amaran and Aputure light since
   the LS 300d II is. The amaran Verge is.
2. **They have been paired at least once with an amaran app.** Pairing is what
   creates the mesh and generates its keys. An unpaired, factory-fresh light has
   no keys to export.
3. **You can get to a Mac or Windows machine running amaran Desktop.** There is
   no Linux build, and the desktop app's database is the only practical source
   for the keys. You need it once, not forever.
4. **The machine that will run the daemon has a working Bluetooth radio.**
   Check with `bluetoothctl list` — empty output means no adapter.
   On Linux the daemon also needs a patched BLE transport that talks to BlueZ
   over D-Bus; the stock daemon drives raw HCI and will not connect. See
   "Running the daemon on Linux" in the README.
5. **Node.js 20 or newer** is installed on that machine.

## Why keys are needed at all

amaran fixtures have no Wi-Fi, no HTTP API, and no open pairing mode. They form
a **Bluetooth Mesh** — an encrypted network where every message is authenticated
against two secrets shared by the whole network:

- the **network key** (`netKey`), which authenticates mesh traffic, and
- the **application key** (`appKey`), which encrypts the payload of a command.

The amaran app generates both when it first pairs your lights, and keeps them in
its own database. Without them, a fixture ignores you — it cannot tell a command
from noise. There is no way to ask a light for them, and no open-source
provisioner that would let you enrol the lights into a mesh of your own.

So the job is to copy the keys out of the app that already has them.

Alongside the keys you need each fixture's **mesh address** — a small integer
(2, 4, 6 …) assigned at pairing, which is how a command is addressed to one
light rather than all of them — and its **Bluetooth MAC**, used to open the
proxy connection.

## Getting the keys

### Option A — the export script (recommended)

On the Mac or Windows machine with amaran Desktop:

1. Open amaran Desktop and confirm it sees and controls your lights.
2. Copy `tools/amaran-export-keys.sh` from this repo over.
3. Run it:

   ```bash
   ./amaran-export-keys.sh lights.json
   ```

It finds `~/Library/Application Support/amaran Desktop/*/amaran.db`, copies it
(the app holds the live database open), reads the keys and fixtures, and writes
a `lights.json` with everything the daemon needs.

Move that file to the Linux machine privately:

```bash
scp lights.json you@linux-box:~/
```

Then on the Linux machine, click **Set up lights…** in the panel (or run
`tools/amaran-setup`), choose **import**, and point it at the file.

### Option B — read the database by hand

If the script cannot find the database or the app's schema has moved, do it
manually. On the Mac:

```bash
# Find it
find ~/Library/Application\ Support -name amaran.db

# Copy it aside — the app keeps the live one open
cp ~/Library/Application\ Support/amaran\ Desktop/*/amaran.db /tmp/

# The two keys
sqlite3 /tmp/amaran.db "SELECT net_key, app_key FROM mesh LIMIT 1;"

# Your fixtures
sqlite3 /tmp/amaran.db "SELECT mac_address, node_address, name FROM fixtures WHERE node_address > 1;"
```

On Windows the database lives under `%APPDATA%` or `%LOCALAPPDATA%` in an
`amaran Desktop` folder.

If the `mesh` table is not there, dump the schema and look for the equivalent:

```bash
sqlite3 /tmp/amaran.db ".tables"
sqlite3 /tmp/amaran.db ".schema"
```

### Option C — type them in

With the values from Option B in hand, click **Set up lights…** in the panel and
choose **type the keys in by hand**. It asks for the two keys (hidden input, so
they stay out of your scrollback), then each light's name, MAC, and mesh
address, and writes the config for you.

## Where the keys end up

In `lights.json`, in the daemon's directory — `~/.config/amaran-BLE-control/lights.json`
by default. The widget itself never stores them.

That is deliberate. Omarchy's `shell.json` is a normal-permission config file
that gets shared in screenshots and pasted into issues; mesh keys do not belong
there. `lights.json` is written `0600` and read only by the daemon.

If your daemon lives elsewhere, set **Daemon directory** in the widget settings
so the setup button writes to the right place.

## Keeping them safe

- The keys are a credential for your lights. Anyone with them and Bluetooth
  range can turn your lights on, off, or blinding.
- `lights.json` is written `0600`. Keep it that way.
- Never commit it. This repo's `.gitignore` already excludes `lights.json` and
  `*.db`, but check before you push.
- Move it between machines with `scp`, not by pasting into chat.
- To rotate them, factory-reset the lights and re-pair in the amaran app, then
  export again.

## When an assumption does not hold

**No Bluetooth adapter on the Linux machine.** Check `bluetoothctl list`. Empty
means the kernel sees nothing. On a desktop, look in BIOS under Onboard Devices
for a Bluetooth Controller toggle, then confirm with
`sudo dmesg | grep -i bluetooth`. Otherwise: a USB BLE dongle, or run the daemon
on another machine and set the widget's **host** setting to point at it.

**No Mac or Windows machine.** amaran Desktop is the only reasonable key source.
A borrowed machine works — install it, pair the lights, export, uninstall. The
lights keep working with your phone afterwards; exporting changes nothing on
them.

**Lights paired only with the phone app.** The keys are in the phone app's
private storage, which needs root on Android or an encrypted-backup extraction
on iOS. Pairing the same lights with amaran Desktop is far less painful.

**Lights never paired at all.** Pair them in an amaran app first. Enrolling them
into a mesh of your own would mean writing a BLE Mesh provisioner, which does
not exist for these fixtures today.

**The daemon starts but finds no lights.** Close amaran Desktop and quit the
phone app. A fixture already serving one proxy client will refuse a second.

**`/sys/class/bluetooth` exists but `bluetoothctl list` is empty.** The
`bluetooth` kernel module is loaded but no `hci*` adapter registered — the
radio is not reaching the kernel at all. That is a firmware/BIOS/enumeration
problem, not a daemon one; check `sudo dmesg | grep -i -E 'bluetooth|usb'` for
errors like `device descriptor read/64, error -110`.

**The daemon cannot open the adapter.** On Linux it needs raw HCI access:

```bash
sudo setcap cap_net_raw+eip "$(readlink -f "$(which node)")"
```

Re-run that after every Node upgrade — the capability is on the binary.
