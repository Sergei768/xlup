# xlup

[![License: BSD 3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform: Debian](https://img.shields.io/badge/Platform-Debian%20family-A81D33.svg?logo=debian&logoColor=white)](https://www.debian.org/)
[![Platform: Devuan](https://img.shields.io/badge/Platform-Devuan-404A60.svg)](https://www.devuan.org/)


A minimal Bash script to build, install, and update [XLibre](https://github.com/X11Libre) from source.

## Features

- Builds XLibre and selected drivers from source.
- Installs to `/usr/local` without replacing the system Xorg installation.
- Creates backups and attempts rollback if an installation fails.
- Checks for updates and supports weekly automatic updates.
- Removes files installed by `xlup`.

## Requirements

- Debian, Ubuntu, Devuan, or a derivative.
- Bash, an internet connection, and `sudo` if not running as root.
- At least 1 GB of free space in `/var/cache/xlup`.

## Usage

```bash
chmod +x xlup
sudo ./xlup
```

### Options

| Command | Description |
| --- | --- |
| `sudo ./xlup` | Install or update XLibre |
| `sudo ./xlup -c` | Check for updates |
| `sudo ./xlup -a` | Enable weekly automatic updates |
| `sudo ./xlup -A` | Disable automatic updates |
| `sudo ./xlup -d` | Show instructions for using XLibre as the default X server |
| `sudo ./xlup -x` | Remove files installed by `xlup` |
| `sudo ./xlup -y` | Run without interactive confirmation |
| `sudo ./xlup -h` | Show help |

When checking for updates, `xlup -c` exits with code `10` if updates are available.

## Notes

The script installs system packages and files, so run it as root or through `sudo`. Before making changes, it creates backups of X11 configuration and system Xorg files. The three most recent backups are kept in `/var/lib/xlup/backups`.
