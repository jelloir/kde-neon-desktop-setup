# KDE Neon Btrfs Setup Script

## Purpose
Automates creation of optimized Btrfs subvolumes (@var_log, @var_cache, @snapshots) after a fresh KDE Neon installation with LUKS encryption.

## Features
- ✔️ Creates essential Btrfs subvolumes
- ✔️ Preserves existing data through safe migration
- ✔️ Uses LUKS mapper paths for consistency
- ✔️ Designed for LiveCD post-install environment
- ✔️ Minimal dependencies (just core Linux utilities)

## Usage
1. Install KDE Neon using Calamares (with LUKS+Btrfs)
2. Boot into LiveCD environment
3. Run: `sudo ./btrfs-setup.sh`
