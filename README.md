# aion-kit-windows

Running [aion-kit](https://github.com/iliyarka87/aion-kit) on **native Windows** —
without WSL2.

`aion-kit` is Unix-shaped by design and says so honestly in its INSTALL. This
repository is the missing half: what breaks on native Windows, why, and the
smallest fix for each. Everything here was reproduced on a real machine
(Windows 10 Home, Python 3.14, PowerShell 5.1) — nothing is written from memory.

MIT. Take it and build your own.

---

## The UTF-8 trap

**Symptom.** You run the gate's own probes on native Windows and most of them
report failure:

```
Exception in thread Thread-1 (_readerthread):
UnicodeDecodeError: 'charmap' codec can't decode byte 0x90 in position 7
...
RESULT: MISMATCHES FOUND
```

You conclude the gate is broken. **It is not.**

**Cause.** The probe launches the gate as a child process:

```python
subprocess.run([sys.executable, "vorota.py", *args], cwd=d,
               capture_output=True, text=True)
```

`text=True` without `encoding=` decodes the child's output using the *console*
code page — `cp1252` or `cp866` on Windows, never UTF-8. The gate prints
non-ASCII text. The decode raises, the probe sees nothing, and reports a
mismatch that never happened.

**Proof it is the decode and not the logic.** Same command, same files, one
environment variable:

```powershell
$env:PYTHONUTF8 = "1"
python proby.py
```

Every probe passes.

**Two fixes.**

The right one, in the caller:

```python
subprocess.run([...], capture_output=True, text=True,
               encoding="utf-8", errors="replace")
```

The quick one, at the entry point:

```python
# at the very top, before any subprocess call
import sys
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
```

or set `PYTHONUTF8=1` in the environment / the workflow.

`tests/test_utf8_trap.py` reproduces the trap and proves the fix. It fails on
a machine where the trap is not fixed and passes where it is, so it is a
regression guard, not a description.

---

## What does not run natively at all

Checked on the machine, not guessed:

| piece | why | what to use instead |
|---|---|---|
| the socket door | `socket.AF_UNIX` does not exist in CPython on Windows | WSL2, or a TCP/named-pipe port |
| the process lock | `fcntl` is Unix-only | `msvcrt.locking` |
| `nohup`, `*-timer.sh` | no such thing on Windows | Task Scheduler |
| `sync/*.plist` | `launchd` is macOS-only | Task Scheduler |

Check the first one yourself in one line:

```powershell
python -c "import socket; print(hasattr(socket, 'AF_UNIX'))"
```

`False` means the socket door will not open here, no matter what else you do.

The pure-Python parts — the checklist gate and most of the `bin/*.py`
tools — do run natively once the UTF-8 trap is out of the way.

---

## The wall: a least-privilege account

`aion-kit` assumes agents run as a user that cannot write to your canon. On
macOS that is a second account plus `sudo`. On Windows it is a second local
account plus UAC — and UAC is the stronger boundary of the two for this
purpose, because an agent driving the keyboard cannot click the consent
dialog.

`scripts/New-AgentUser.ps1` creates that account and collects the evidence
that it is powerless.

```powershell
# from an elevated PowerShell
.\scripts\New-AgentUser.ps1 -UserName agent -Protect "C:\path\to\your\canon"
```

What it does:

- creates a local user if it is missing, with a 20-character password it
  generates itself — you never type one;
- writes that password to your own profile directory, not into the repository;
- puts the user in **Users**, and removes it from **Administrators** if it
  somehow got there;
- writes an evidence file: the account list, both group memberships, and the
  ACLs of every path you named, with a verdict line per path.

What it does **not** do: it deletes nothing, touches no other account, and
changes no ACLs. Granting or denying rights is a separate, later step —
one change at a time.

Run it with `-WhatIf` first if you want to see the plan without the act.

### Two Windows limits that cost us three runs

- **Account description: 48 characters maximum.** `New-LocalUser` rejects
  anything longer and the account is not created.
- **`icacls` permission arguments from PowerShell.** Writing
  `"$env:USERNAME:(F)"` inline gets split and `icacls` answers
  `Invalid parameter "(F)"`. Build the string into a variable first, or do
  not call `icacls` for this at all — a file inside your own profile is
  already unreachable by other local accounts.

Both were found the hard way. A syntax check does not catch either: the
syntax was valid both times, the values were not.

---

## Requirements

- Windows 10 or 11
- Python 3.9+
- PowerShell 5.1 (ships with Windows) or PowerShell 7
- Git

No third-party packages.

## Tests

```powershell
python -m unittest discover -s tests -v
```

The same tests run on `windows-latest` in GitHub Actions on every push.

## Honest limits

- Tested on one machine: Windows 10 Home, Python 3.14, PowerShell 5.1.
  Windows 11 and PowerShell 7 are expected to work and are **not** verified.
- This repository does not port the socket door. It tells you it cannot
  open natively and points at WSL2.
- `New-AgentUser.ps1` creates the account. Making your canon readable but
  not writable by that account is not done here.
- Nothing here weakens `aion-kit`'s rules. It only makes the parts that are
  already pure Python run where they otherwise silently fail.

## Contributing

Issues and pull requests welcome. If you are reporting a break, include the
exact output and your `python --version` and `$PSVersionTable.PSVersion`.

## License

MIT — see `LICENSE`.

## Status

CI is green on windows-latest for Python 3.9 and 3.12.
