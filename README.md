# Migrate-FileServer

A guided, interactive PowerShell CLI for migrating Windows file server shares
(folder **plus** SMB share permissions) from an old server to a new one, one
department at a time, while preserving NTFS ACLs and ownership.

Built around `robocopy` for the data and `New-SmbShare`/`Get-SmbShareAccess`
for the share-level permission that `robocopy` does **not** carry. Targets
Windows Server in an Active Directory domain, where SIDs resolve identically on
both sides so copied ACLs work without remapping.

---

## Features

- **Menu-driven** — no parameters to memorize; safe for junior operators.
- **Three-phase workflow** designed to be interruption-proof: `Baseline` -> `Delta` -> `Cutover`.
- **Preserves** NTFS ACLs, ownership, timestamps and the SMB share-level ACL.
- **Reusable profiles** — enter a department's details once, reuse across phases.
- **Live progress bar with ETA** (bytes copied, MB/s, estimated time remaining).
- **Built-in validation** — root-ACL parity check and an orphaned-ACE scan
  (catches ACEs pointing at local accounts of the old server / unresolved SIDs).
- **Locale-independent** parsing (works on non-English Windows).
- **Dry-run** mode and reinforced confirmation before the destructive cutover.
- **100% ASCII source** so it parses correctly under any file encoding.

---

## Requirements

- Windows PowerShell **5.1** (or later).
- Run **as Administrator** (required to read/write ACLs and manage shares).
- Source and destination in the **same Active Directory domain** (so SIDs match).
- **WinRM** enabled on both servers (`Enable-PSRemoting`) — the share step uses
  remote CIM sessions to read the old share ACL and create the new one.
- The account running the script needs read on the source (backup mode `/B` is
  used) and admin rights on the destination server.

---

## Quick start

```powershell
# from an ADMINISTRATOR PowerShell
.\Migrate-FileServer.ps1
```

If the script is blocked by execution policy (it is unsigned), run it once with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Migrate-FileServer.ps1"
```

For a permanent setup on a server, prefer signing the script or:

```powershell
Unblock-File .\Migrate-FileServer.ps1          # clear the "downloaded" mark
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

> If `Get-ExecutionPolicy -List` shows the policy locked at `MachinePolicy`,
> it comes from Group Policy and must be handled with whoever owns the GPO.

---

## Usage

From the main menu:

1. **Register a NEW department** — the wizard asks for the source path,
   destination path, share name, source/destination server names and thread
   count, validating each as you go, then saves a profile.
2. **Work on an existing department** — pick a saved profile and run a phase.

### The three phases

| Phase      | robocopy mode | When to run | Behavior |
|------------|---------------|-------------|----------|
| `Baseline` | `/E`          | First pass, old server live, users working | Adds files only; never deletes |
| `Delta`    | `/E`          | Repeat passes before cutover | Copies only what changed; fast |
| `Cutover`  | `/MIR`        | Final pass (old share set read-only) | Mirrors, then (re)creates the SMB share on the new server |

Each phase offers a **dry run** first (estimate only, copies nothing). The
cutover additionally requires confirming the old share is read-only and typing
the department name to proceed.

After cutover, point your **DFS namespace** at the new target and only then
release user access. Keep the old server as a rollback for a few days.

---

## How it works

- **Data + ACLs**: `robocopy /COPYALL /DCOPY:DAT /SECFIX /B`. `/COPYALL` carries
  data, attributes, timestamps, the NTFS security descriptor (DACL), owner and
  auditing (SACL). `/B` (backup mode) reads files even where the operator is not
  in the ACL.
- **Share permission**: copied separately via CIM. `robocopy` only touches the
  filesystem ACL — the SMB share-level ACL lives in the registry. The script
  reads the old share's access, recreates the share on the destination,
  removes the default `Everyone = Read`, and reapplies the source's ACEs
  faithfully.
- **Estimate + progress**: a `robocopy /L` (list-only) pre-pass computes the
  exact bytes to copy, giving an honest percentage and ETA even on delta runs.
- **Locale-proof parsing**: `/NC` (no class column) makes each file line
  `<bytes> <path>`, so parsing does not depend on translated labels like
  "New File".
- **Exclusions**: `/XF ~$* *.tmp Thumbs.db` skips Office lock files and shell
  junk. These are transient and frequently vanish mid-copy, which would
  otherwise raise `ERROR 2`.
- **Validation**: after each phase the script compares the root folder's SDDL
  between source and destination and scans for orphaned ACEs, writing a CSV if
  any are found.

### robocopy exit codes

`robocopy` returns a **bitmask**, not a severity scale. The script treats it as:

| Code      | Meaning | Script behavior |
|-----------|---------|-----------------|
| `0`       | Nothing to copy (in sync) | OK |
| `1`-`7`   | Files copied / extras / mismatch | OK (success) |
| `& 8`     | Some files not copied (open, locked, vanished) | **Warning, continues** (expected on a live baseline) |
| `>= 16`   | Fatal error (e.g. disk full, invalid path) | **Aborts the phase** |

---

## Output

The script creates two folders next to itself:

- `profiles/` — one JSON per department (paths, servers, thread count, and a
  run history with timestamps and results).
- `migration-logs/` — robocopy logs, orphaned-ACE CSVs and SDDL comparisons,
  named per department and phase.

---

## Configuration

Near the top of the script:

```powershell
$UseUnicodeBar = $true   # set to $false if the progress bar shows boxes
```

Thread count (`/MT`, 1-128) is asked per department. More threads help with
**many small files**; they do little for a few huge files and can hurt a
spinning-disk source if set too high. 16 is a sane default; measure MB/s on a
delta run and adjust.

---

## Troubleshooting

- **"cannot be loaded ... not digitally signed"** — execution policy. See
  *Quick start*.
- **Banner/bar shows garbled characters or parse errors on load** — the file
  must stay ASCII. If you edit it, save as ASCII/UTF-8 and avoid introducing
  accented characters or symbols into the code.
- **Estimate shows `0 files`** — either the destination already contains the
  data (a re-run is genuinely a no-op) or the source path is empty/wrong.
  Verify the source has content and the destination is empty for a first
  baseline.
- **`ERROR 2 ... cannot find the file`** on `~$...` files — Office lock files
  that vanished mid-copy. Already excluded via `/XF`; harmless.
- **`ERROR 32` (file in use)** — normal during a live baseline; a later
  delta/cutover (with the share read-only) picks them up.
- **`ERROR 112` (disk full)** — fatal; free or grow the destination volume and
  re-run. Already-copied data stays; robocopy resumes incrementally.
- **Share step fails** — confirm WinRM is enabled on both servers and that the
  destination path is **local** to the destination server (e.g. `E:\Data\X`),
  not a non-admin UNC.

Recovery is always safe: robocopy is incremental (it skips files already
identical at the destination), so if any pass is interrupted, just run it
again — it resumes rather than restarting.

---

## Known limitations

- During `Cutover` (`/MIR`), "extra" files being deleted from the destination
  are counted in the progress total, so the bar can look slightly off when many
  extras exist. The copy/delete itself is correct.
- Share creation expects a **local path** on the destination server. UNC works
  only for admin shares (`\\server\e$\...`).
- The orphaned-ACE scan checks the root and its immediate children by default
  (a deep scan exists in code but is not exposed in the menu).

---

## Safety notes

- Pilot on a small, low-risk share first.
- For shares holding personal or regulated data, keep the destination's access
  control as strict as the source and validate the procedure with your security
  team. Enable the log-privacy option (suppresses file names in logs) for
  sensitive folders; robocopy never logs file **contents**.

---

## License

Add your license of choice here (e.g. MIT).
