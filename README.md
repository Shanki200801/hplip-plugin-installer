# hplip-plugin-installer

Install HP's proprietary HPLIP plugin when `hp-plugin` fails with:

```
error: Unable to load pkit...is HPLIP installed?
error: Python gobject/dbus may be not installed
```

Seen on **Linux Mint 22 / Ubuntu 24.04** with the distro's `hplip` package. `hp-plugin` crashes before copying any files, even when run with `sudo`. Printing then fails, and the CUPS log (`journalctl -u cups`) shows:

```
hpcups: validate_plugin_version() Failed to get Plugin version from [/var/lib/hp/hplip.state]
hpcups: Plugin version is not matching
hpcups: m_Job initialization failed with error = 48
```

or

```
unable to load library /usr/share/hplip/prnt/plugins/lj.so: cannot open shared object file
```

Affects printers that need the plugin, such as the LaserJet Pro / Professional M1132, M1136 and P1102 MFPs, and models listed with `plugin=1` in `/usr/share/hplip/data/models/models.dat`.

## Usage

```bash
git clone https://github.com/Shanki200801/hplip-plugin-installer.git
cd hplip-plugin-installer
sudo ./install-hp-plugin.sh
```

Then power-cycle the printer and print a test page:

```bash
lp /usr/share/cups/data/testprint
```

If the printer isn't added yet, run `hp-setup -i` after installing.

| Option | |
|---|---|
| `--dry-run` | Download, verify and unpack only. No root needed, installs nothing. |
| `--yes` | Accept HP's license without prompting. |
| `--version X.Y.Z` | Use a specific plugin version. It must match your HPLIP version. |
| `--keep` | Keep the temporary work directory. |

## What it does

1. Reads your installed HPLIP version from `/etc/hp/hplip.conf`.
2. Finds the matching plugin and its checksum in HP's index ([hplip.sourceforge.net/plugin.conf](https://hplip.sourceforge.net/plugin.conf)).
3. Downloads the plugin from HP's mirror (openprinting.org) over HTTPS and **verifies the checksum**.
4. Unpacks the self-extracting archive **without running it**.
5. Shows HP's license and asks you to accept it.
6. Installs the files with **HPLIP's own copy routine** (`installer/pluginhandler.py: copyFiles`). That is the code `hp-plugin` runs, minus the broken PolicyKit step.
7. Checks that the driver libraries actually landed, then restarts CUPS.

Step 7 matters because `copyFiles` silently skips files it can't find, yet still marks the plugin as installed.

## Notes

- **No HP files are in this repo.** The plugin is proprietary, and HP's license forbids redistributing it. The script downloads it from HP's mirror at run time.
- **After an HPLIP upgrade,** the installed plugin no longer matches the new version. Run the script again, or try `hp-plugin -i` first in case the upgrade fixed it.
- **Undo:** `sudo rm -rf /usr/share/hplip/prnt/plugins /usr/share/hplip/scan/plugins /usr/share/hplip/data/firmware`, then delete the `[plugin]` section from `/var/lib/hp/hplip.state`.

## License

MIT for the script; see [LICENSE](LICENSE). The HP plugin it downloads is covered by HP's own license.
