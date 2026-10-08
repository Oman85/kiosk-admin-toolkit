# Moving to Kiosk Fleet Web (PowerShell)

This version replaces both earlier ones: the PowerShell Kiosk Fleet (`Start-FleetWeb.ps1`, its scheduled task, and the scheduled collector `Collect-MWSTFleet.ps1`) and Kiosk Fleet Web 2 in Python, which ran on Linux in Docker. The kiosks don't change: the same launchers, the same files in their Public Documents, and the same events CSV for the Power BI report.

## From the Python version (kiosk-fleet-web, Docker)

| Python, in Docker | PowerShell, on Windows |
|---|---|
| `docker compose up -d` | `Install-KioskFleetWeb.ps1`: a scheduled task for the server, a service for Caddy. |
| The container's port 8080, HTTPS from `deploy/docker-compose.https.yml` or `KFW_TLS_CERT` | Caddy on 443, with your certificate (`-CertificateFile`, `-KeyFile`) or its own. |
| `/data` (a Docker volume) | `C:\ProgramData\KioskFleetWeb`. |
| `kfw.sqlite3`: accounts, sessions, audit | `users.json`, `sessions.json`, `audit.jsonl`. |
| `KFW_*` in `docker-compose.yml` | `KFW_*` in `kfw.env` in the data folder. Same names. |
| `KFW_SHARE_USER` + `KFW_SHARE_PASSWORD_FILE` (a Docker secret), opened with smbprotocol | The service account itself (a gMSA, say), or `Save-KioskShareCredential.ps1`: Windows opens the shares. |
| `kfw user ...` | `Set-KioskFleetUser.ps1 ...`, same actions. |
| `kfw scan` | `Invoke-FleetScan.ps1`. |
| `TZ` | The server's own time zone. |
| Collector version `6.2-py` | `6.2-ps`, in the COLLECTOR_RUN rows and the status file. The rows themselves are the same, byte for byte (`Tests/Parity/Compare-WithPython.ps1`). |

Moving over:

1. Install with `Install-KioskFleetWeb.ps1`, with the settings you had in `docker-compose.yml` (`-ShareTemplate`, `-SiteName`, or in `kfw.env`).
2. Copy from the volume into `C:\ProgramData\KioskFleetWeb`: `MWST_FleetEvents.csv` and `.status.json`, the kiosk list (`kiosk-list.*`), and `logs\snapshots\` if you want the pictures. With `KFW_PUBLISH_CSV` set there is nothing to copy for the CSV: the collector reads the published one and merges it with its own.
   ```bash
   docker compose cp kfw:/data/MWST_FleetEvents.csv .
   docker compose cp kfw:/data/MWST_FleetEvents.status.json .
   docker compose cp kfw:/data/kiosk-list.xlsx .
   ```
3. Accounts do not carry over from `kfw.sqlite3`; make them again in *Users* (tick "choose their own at first sign-in"), or with `Set-KioskFleetUser.ps1 add`. Accounts from the old PowerShell server's `web-users.json` still import with their passwords.
4. **Stop the container** (`docker compose down`) before the first scan here. Two collectors writing the same published CSV make OneDrive conflict copies.

## From the PowerShell Kiosk Fleet (Start-FleetWeb.ps1)

| PowerShell Kiosk Fleet | Kiosk Fleet Web |
|---|---|
| `Start-FleetWeb.ps1`, `Install-FleetWeb.ps1` | `Install-KioskFleetWeb.ps1`. |
| Windows sign-in, `-AdminGroup`, `-OperatorGroup` | Gone. Everyone has an account of the app. |
| `Set-FleetWebUser.ps1`, `Config\web-users.json` | *Users* on the page, or `Set-KioskFleetUser.ps1`. Old accounts: `Set-KioskFleetUser.ps1 import web-users.json`. |
| `Save-KioskCredential.ps1`, `Config\kiosk-admin.cred.xml` | The service account, or `Save-KioskShareCredential.ps1`. |
| `Collect-MWSTFleet.ps1`, `Install-CollectorTask.ps1` | Auto-scan, on by default every 15 minutes; *Scan now*; `Invoke-FleetScan.ps1`. |
| The kiosk list found through OneDrive | Uploaded in *Settings* and edited in *Kiosk list*, or `KFW_KIOSK_LIST`. |
| `MWST_FleetEvents.csv` next to the master list | `MWST_FleetEvents.csv` in the data folder, plus `KFW_PUBLISH_CSV` for the published copy. |
| `Logs\web-audit.log` | The *Audit log* view; *Download all (CSV)*. |
| `Logs\run\` | `logs\run\` in the data folder: scan output. |
| `Deploy-*.ps1`, the Deploy view | Not carried over: deploys are not done from here. |
| The launchers' `EXAMPLE.json` | Shipped with the app (`KioskFleetWeb\templates\`), for the config editor; others through `KFW_TEMPLATES_DIR`. |
| `Show-FleetManager.ps1`, `Show-FleetDashboard.ps1` | Still work against the same CSV, if anyone needs them. |

Moving over:

1. Install, as in the README, and make the first admin account.
2. Upload the master kiosk list in *Settings*, then test one kiosk (*Test a kiosk...*).
3. Bring the history across: copy the current `MWST_FleetEvents.csv` (and its `.status.json`) into the data folder before the first scan - or set `KFW_PUBLISH_CSV` to the published one, and the collector merges it.
4. Import the accounts: `Set-KioskFleetUser.ps1 import web-users.json`. People who signed in with Windows get new accounts in *Users*.
5. **Stop the old collector**: `Install-CollectorTask.ps1 -Unregister`, turn off auto-scan in the old manager, and `Install-FleetWeb.ps1 -Uninstall`.

## Behaviour that is the same

- Every host status (OFFLINE, NO_ACCESS, NO_AGENT, STALE, LOOP_GUARD, the launcher statuses, AGENT_OUTDATED, INACTIVE) is decided as before.
- Reboot counting is the same: one boot is one reboot, `IsCanonicalReboot` / `IsScriptReboot`, the upgrade cutoff, and retention.
- The CSV columns, their order, the quoting and the BOM are unchanged. Status rows are written on change and as a daily keepalive; COLLECTOR_RUN rows hourly; the status file on every run.
- Control files, `password.seed`, the message inbox, snapshots and the config editor work as in the manager. Control files say `by alice (admin) from Kiosk Fleet Web`.

## Behaviour that differs

- Restarts are not sent over WMI/CIM. **Restart...** writes `restart.txt` with the countdown and message, and the launcher has Windows restart the kiosk (`shutdown.exe /r`). A kiosk without one of the new launchers cannot be restarted from here.
- There are no deploys.
- `-RemoteEventLog` is not available. The agents' ledgers carry the same 1074/6005/6008 records with the same EventIds.
- Only each kiosk's Public Documents is opened. A launcher log kept elsewhere is not read.
- Wrong-password counts are kept in memory; a restart of the server clears them.
