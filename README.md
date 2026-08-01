# OmaBackup

An automated configuration backup and migration utility for Omarchy Linux environments.

OmaBackup scans your local configuration files, compares them against upstream Omarchy repositories, isolates custom modifications and local additions, and translates legacy Hyprland `.conf` files into the Quattro Lua format.

---

## Features

* **Automated Branch Detection**: Automatically determines whether your system is running Omarchy 3.8.x (`master`) or Omarchy 4.0.x / Quattro (`quattro`).
* **Differential Backups**: Separates customized core files (`modified/`) from standalone user additions (`local-only/`).
* **Format Migration**: Automatically converts Hyprland `.conf` directives to Quattro Lua configuration equivalents.
* **Dry-Run Mode**: Safely test and inspect backup plans without modifying or copying files.
* **Stand-alone Conversion**: Includes an integrated CLI tool to convert individual `.conf` files on demand.

---

## Prerequisites

Ensure the following dependencies are installed on your system:

* **Bash** (version 4.0 or higher)
* **Python 3** (for the `.conf` to `.lua` conversion engine)
* **Git** (for fetching upstream tracking branches)
* **jq** (optional, recommended for normalized JSON diffs)

---

## Installation

Clone the repository to your preferred local directory:

```bash
git clone [https://github.com/Deoxizn/OmaBackup.git](https://github.com/Deoxizn/OmaBackup.git)
cd OmaBackup
chmod +x omarchy-backup.sh