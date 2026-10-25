#!/usr/bin/python3
"""Atomically replace only the Pi's owned input table; preserve Docker routing."""
import os
from pathlib import Path
import stat
import subprocess
import sys

if os.geteuid() != 0:
    raise SystemExit('Root is required')
path = Path('/etc/pi-guard.nft')
info = path.lstat()
if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o077:
    raise SystemExit('Firewall policy must be a root-owned private regular file')
exists = subprocess.run(['nft', 'list', 'table', 'inet', 'pi_guard'], capture_output=True).returncode == 0
data = ('delete table inet pi_guard\n' if exists else '') + path.read_text()
subprocess.run(['nft', '--check', '--file', '-'], input=data, text=True, check=True)
if sys.argv[1:] == ['--check']:
    raise SystemExit(0)
if sys.argv[1:]:
    raise SystemExit('Usage: apply_guard.py [--check]')
subprocess.run(['nft', '--file', '-'], input=data, text=True, check=True)
