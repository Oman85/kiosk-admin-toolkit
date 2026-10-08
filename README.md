# Kiosk Fleet Web

Every kiosk screen, and what can be done to it, in a browser. It runs on a Windows server: PowerShell 7, with Caddy in front of it for HTTPS.

It is the Kiosk Fleet dashboard and manager as a web app:

- **The dashboard**: Overview, Mach2, Power BI, Web pages and Other, with everything that needs attention at the top, a week of reboots, and every kiosk's details.
- **Kiosk actions**: Read live, Screenshot, Reload, Restart browser, Hold / Resume, Stop, Log, Message, the sign-in Password, the kiosk's own Config (including a new screen or a new kiosk), and Restart the PC.
- **The collector**: *Scan now* and *Auto-scan*. It writes the same `MWST_FleetEvents.csv` and `.status.json` as `Collect-MWSTFleet.ps1`, byte for byte, so the Power BI report keeps working unchanged.
- **Accounts**: sign-in with accounts of the app itself, with no Windows or AD sign-in. Admins manage the accounts on the page. There are two roles, operator and admin.
- **An audit log** of every sign-in, every action on a kiosk, every scan and every account change. It can be searched on the page and downloaded as CSV.
- **Many kiosks at once**: tick kiosks on a tab, or a whole location, and Read live, Reload, Restart browser or send a Message to all of them. Each kiosk's result shows as it comes in.
- **Screens**: the newest screenshot of every kiosk screen in a grid, with *Take new screenshots* for all of them, or a retake every few minutes while the page is open.
- **History**: one kiosk over 1 week to 90 days. It shows a status timeline, reboots per day (the watchdog's marked), how long the kiosk stayed up between reboots, and its events. It is worked out from the events CSV the scans already keep.
- **The kiosk list, edited in the app**: add a kiosk, change its location or type, stop scanning it, or remove it, without uploading the spreadsheet again.

```
 browser ──HTTPS──► Caddy (service KioskFleetCaddy)
                     ├─ the page: KioskFleetWeb\web
                     └─ /api, /healthz ──► 127.0.0.1:8081: Start-KioskFleetWeb.ps1
                                           (scheduled task "Kiosk Fleet Web", as the service account)
   reads   kiosk list (.xlsx/.csv/.txt, uploaded in Settings)
   scans   every kiosk's Public Documents share ───► MWST_FleetEvents.csv + .status.json
   sends   control files (restart.txt too),
           messages, password.seed ────────────────► that share, as the service account
   keeps   accounts, sessions, the audit log ──────► C:\ProgramData\KioskFleetWeb
```

## Try it

On a Windows server with [PowerShell 7.4](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) or later, in PowerShell 7 as an administrator, from the unpacked repository:

```powershell
.\Install-KioskFleetWeb.ps1 -Demo -AdminUser admin
```

It asks for the admin's password, then opens `https://<this server>`. The demo fleet is folders standing in for kiosks, with a thread playing their launchers. Every button works on it, and nothing touches a real kiosk. Caddy makes its own certificate for it, so the browser warns until its root is trusted (below).

Without installing anything, on any computer with PowerShell 7:

```powershell
.\Start-KioskFleetWeb.ps1 -Demo -DataDir .\data -Listen http://localhost:8080/
```

The console prints a one-time link, `/setup?token=...`, which makes the first admin account. (Run it as an administrator on Windows, or reserve the URL first: `netsh http add urlacl url=http://localhost:8080/ user=%USERNAME%`.)

## Run it for real

1. **Who opens the kiosks.** The app only ever opens each kiosk's Public Documents (`C:\Users\Public\Documents`), where the launchers keep their configs, status, logs and control files. It opens them as the account the server runs as. The usual choice is a group managed service account (gMSA), for example `CONTOSO\svc-kioskfleet$`. `NT AUTHORITY\NETWORK SERVICE` also works: on the network it is the server's computer account (`CONTOSO\SERVER$`), and that account then needs the rights on the kiosks. Until the kiosks have a share of their own for it, the path is `\\{0}\C$\Users\Public\Documents`, through the admin share, so the account needs admin rights on the kiosks for now. Once there is a share (say `\\{0}\KioskDocs`), give `-ShareTemplate '\\{0}\KioskDocs'`, and the account only needs change rights on that share.

   To keep a separate account for the shares instead, give `-ShareUser` (or run `Save-KioskShareCredential.ps1` later). Its password is kept with DPAPI for this server only.
2. **A certificate.** Give `-SiteAddress https://kiosks.contoso.local` with `-CertificateFile` and `-KeyFile` (PEM) from your CA. Without them, Caddy makes its own: trust its root, `C:\ProgramData\KioskFleetWeb\caddy\pki\authorities\local\root.crt`, by group policy.
3. **Install.**
   ```powershell
   .\Install-KioskFleetWeb.ps1 -SiteAddress https://kiosks.contoso.local -CertificateFile .\kiosks.crt -KeyFile .\kiosks.key `
       -ServiceAccount 'CONTOSO\svc-kioskfleet$' -SiteName 'CZECH DIVISION - Nyrany' -AdminUser admin
   ```
   Without `-AdminUser`, it prints the one-time setup link instead. The link is also in `setup-link.txt` in the data folder until it is used.
4. **Upload the kiosk list** in *Settings*. This is the master kiosk list `.xlsx` (NAME/HOST, TYPE, HAS MWST, ACTIVE, LOCATION, RESTART GROUP), a `.csv`, or a `.txt` with one name per line. Then use *Test a kiosk...* on one kiosk to check the account and the network.
5. **Add people** in *Users*.

Auto-scan starts by itself, every 15 minutes, once there is a list. *Scan now* runs one at any time.

`Install-KioskFleetWeb.ps1` can be run again at any time, to update the app from a newer copy or to change a setting it was given. `-Uninstall` removes it but keeps the data folder; `-Uninstall -RemoveData` removes that too.

### What is installed

| | |
|---|---|
| `C:\Program Files\KioskFleetWeb` | The app (`KioskFleetWeb\`, the scripts) and `caddy\caddy.exe`. |
| `C:\ProgramData\KioskFleetWeb` | The data folder, open to administrators, SYSTEM and the service account only. `KFW_DATA_DIR` names it, machine-wide. |
| Scheduled task **Kiosk Fleet Web** | `Start-KioskFleetWeb.ps1` at startup, as the service account, restarted every minute if it stops. Listens on `http://127.0.0.1:8081/`, reserved for that account (`netsh http show urlacl`). |
| Service **KioskFleetCaddy** | Caddy, as NETWORK SERVICE, automatic, restarted on failure. Its config is `caddy\Caddyfile` in the data folder. |
| Firewall rule **Kiosk Fleet Web (Caddy)** | The site's port (443) and 80 (to redirect to it), for Caddy only. 80 is left out when something else holds it (IIS, HTTP.sys) or with `-NoHttpRedirect`. |

### Finding the kiosks

The server finds kiosks by name through the server's own DNS, so short names like `MWEB1` work as they do on the server. It needs to reach the kiosks on 445 (SMB), and ping helps: there is no WMI, CIM or DCOM. **Restart...** writes `restart.txt` for the launcher, which has Windows restart the kiosk after the countdown, so a kiosk without one of the new launchers cannot be restarted from here. *Test a kiosk...* in Settings shows what works.

### The Power BI report

The events CSV lives in `C:\ProgramData\KioskFleetWeb\MWST_FleetEvents.csv`. To publish it where the report reads it, set `KFW_PUBLISH_CSV` to a file in a folder OneDrive or SharePoint syncs, for example `KFW_PUBLISH_CSV=D:\SharePoint\KIOSKS\MWST_FleetEvents.csv` in `kfw.env`. The service account needs to write there. The collector keeps both copies, and each one restores the other. The format is the PowerShell collector's, column for column.

Run **one collector**. Once this server scans, turn off the scheduled `Collect-MWSTFleet.ps1` (`Install-CollectorTask.ps1 -Unregister`) and any auto-scan in the old manager. Two collectors writing the same file make OneDrive conflict copies.

## Who can do what

| | Operator | Admin |
|---|:-:|:-:|
| Every view: Overview, Mach2, Power BI, Web pages, Other, History, Activity | ✓ | ✓ |
| **Scan now** | ✓ | ✓ |
| **Read live**, **Screenshot**, **Log** | ✓ | ✓ |
| **Reload**, **Restart browser** | ✓ | ✓ |
| **Message...** on a Mach2 kiosk | ✓ | ✓ |
| The same on many kiosks at once (ticked, or a whole location) | ✓ | ✓ |
| **Restart...** a kiosk, **Hold / Resume**, **Stop** | | ✓ |
| **Password...**, **Config...**, **Add screen...** | | ✓ |
| **Auto-scan**, stopping a scan | | ✓ |
| **Audit log**, **Users**, **Settings**, **Kiosk list** | | ✓ |

The page only shows the buttons a role can use. The server checks the role again on every request, so a hand-made request gets *403* and an audit entry. The table is in `KioskFleetWeb\Private\Auth.ps1`.

## Screens

**Screens** shows the newest screenshot of every kiosk screen in a grid, each with the kiosk, its status, its location, how old the picture is, and what the launcher said about the page (state, title). Filter by tab, location, name or attention, and pick small, medium or large pictures. A picture opens full size; a kiosk's name opens it on its tab.

**Take new screenshots** (operators and admins) asks every kiosk shown, through `snapshot.txt` - a group action, so busy kiosks and kiosks without a new launcher are skipped. **Retake** does it every 5 to 30 minutes while the page is open in a visible window. A kiosk with several screens gives one picture per screen.

Pictures are kept in `logs\snapshots\` in the data folder: the newest 10 of each screen, for 14 days, and a screen's newest one always.

## Many kiosks at once

On a kiosk tab, tick kiosks, or pick a location in the box next to the filter and tick the box in the header to take every kiosk shown. A bar appears with **Read live**, **Reload**, **Restart browser** and **Message...**; **Screens** takes screenshots of many kiosks the same way. Each kiosk gets a job of its own, as if it had been clicked by itself. The card lists every kiosk and shows its result as it comes in.

Kiosks the action does not fit are skipped and named, not refused as a whole: a kiosk not on the new launcher yet (for Reload and Restart browser), one without a watchdog that can show a message, one busy with something else, or one not in the last scan. Restart, Hold, Stop and the other admin actions are deliberately one kiosk at a time. The audit log has one `group-<action>` entry for the request, plus each kiosk's own entry.

API: `POST /api/group/{live|reload|relaunch|message}` with `{"hosts": [...]}` (plus `text` and `seconds` for a message).

## History

**History** in the menu, or **History** in a kiosk's details, shows one kiosk over 1 week, 2 weeks, 4 weeks or 90 days:

- **Status timeline**: one bar, a block per status. A status holds from its scan until the next one. A gap longer than the keepalive (`KFW_KEEPALIVE_HOURS`, plus three hours) means nothing was scanning, so it shows as *no data*, never as fine.
- **Fine**: the share of the scanned time the kiosk was OK. Not-active time counts neither way.
- **Reboots per day**, with the watchdog's part in red, and under it how fine each day was.
- **Up between reboots**: each stretch from one reboot to the next, and what ended it.
- **Events**: reboots, white screens, watchdog and message events, newest first.

All of it comes from `MWST_FleetEvents.csv`, so it reaches back as far as the CSV does (`KFW_RETENTION_DAYS`, 400 days by default). Nothing new is collected. API: `GET /api/kiosks/{host}/history?days=28`.

## The kiosk list

**Kiosk list** (admins) shows every row of the list, scanned or not, and why not: *inactive* or *not flagged*. **Add a kiosk...**, **Change...** (name, location, type, watchdog, active, restart group, info), **Stop scanning** / **Scan it** (Active = N / Y) and **Remove from the list...** take effect at the next scan. **List entry...** in a kiosk's details opens its row, or a new row filled in from the scan.

The list stays a file. The first change of an uploaded `.xlsx` or `.txt` writes every row of it to `kiosk-list.csv` in the data folder and keeps the original as `kiosk-list-before-edit.xlsx`. The `.csv` can be downloaded, changed in Excel and uploaded again in **Settings**; an upload replaces it as before. Each change is in the audit log (`kiosk-list-add`, `-edit`, `-remove`) with what changed. A list named by `KFW_KIOSK_LIST` is shown but not edited here.

## Accounts and sessions

- Passwords are stored as salted PBKDF2-SHA256 hashes. A password someone chooses for themselves (first setup, *Change your password*, the change at first sign-in) needs at least 12 characters and three kinds of character, or at least 20 characters. An admin setting a password in *Users*, or with `Set-KioskFleetUser.ps1`, can set any password; the audit log notes when it is below those rules. Tick "choose their own at first sign-in" and the person then has to pick one that meets them.
- An admin can add an account with a temporary password ("choose their own at first sign-in"), change a role, disable or remove an account, reset a password, and sign someone out everywhere. A change takes effect at once, on every session. The last admin cannot be removed, disabled or demoted.
- Everyone can change their own password (**Password** at the top). Doing so signs out their other sessions.
- Five wrong passwords for a name within 15 minutes lock that name for 15 minutes. Twenty wrong passwords from one address lock the address. (The count is kept in memory: a restart of the server clears it.)
- A session is an `HttpOnly`, `SameSite=Strict` cookie, `Secure` over HTTPS. It lapses after 30 minutes idle (`KFW_IDLE_MINUTES`) and after 10 hours whatever happens (`KFW_SESSION_HOURS`). Every change also needs a CSRF token and the page's own origin.

From the command line on the server, in PowerShell 7 as an administrator, in `C:\Program Files\KioskFleetWeb`:

```powershell
.\Set-KioskFleetUser.ps1 list
.\Set-KioskFleetUser.ps1 add alice -Role admin       # asks for the password twice
.\Set-KioskFleetUser.ps1 passwd alice
.\Set-KioskFleetUser.ps1 role alice operator
.\Set-KioskFleetUser.ps1 disable alice                # enable, remove
```

It works while the server runs; the server reads the change at once. Accounts from the PowerShell server's `Config\web-users.json` carry over with their passwords, because the hash format is the same:

```powershell
.\Set-KioskFleetUser.ps1 import \\oldserver\c$\KioskFleet\Config\web-users.json
```

## Settings

All settings are `KFW_*` values, in `kfw.env` in the data folder (one `NAME=value` per line) or as environment variables, which win. `Install-KioskFleetWeb.ps1` writes the ones it is given and keeps the rest. A `_FILE` variant reads the value from a file. Restart the server after a change: `Stop-ScheduledTask 'Kiosk Fleet Web'; Start-ScheduledTask 'Kiosk Fleet Web'`.

| Variable | Default | |
|---|---|---|
| `KFW_SHARE` | `\\{0}\C$\Users\Public\Documents` | Each kiosk's Public Documents; `{0}` is its name. A local path makes each kiosk a folder (tests, demos). (`KFW_ROOT_TEMPLATE`, the C: drive, is still read and has `\Users\Public\Documents` added.) |
| `KFW_SHARE_USER`, `KFW_SHARE_PASSWORD(_FILE)` | | An account for the shares other than the service account. `Save-KioskShareCredential.ps1` keeps one encrypted in `share.cred` instead. |
| `KFW_KIOSK_LIST` | | A fixed kiosk list file. Without it, the list is the one uploaded in Settings. |
| `KFW_PUBLISH_CSV` | | A second copy of the events CSV, for the Power BI report. |
| `KFW_AUTOSCAN`, `KFW_AUTOSCAN_MINUTES` | `true`, `15` | Scan by itself, and how often. |
| `KFW_PARALLEL_HOSTS`, `KFW_HOST_TIMEOUT_SECONDS` | `8`, `180` | Kiosks read at once, and when to give up on one. |
| `KFW_STALE_MINUTES` | `45` | When the dashboard calls its data stale. |
| `KFW_RETENTION_DAYS`, `KFW_RECONCILE_DAYS`, `KFW_TRUSTED_FROM_AGENT_VERSION` | `400`, `30`, `6.1` | As for `Collect-MWSTFleet.ps1`. |
| `KFW_IDLE_MINUTES`, `KFW_SESSION_HOURS` | `30`, `10` | How long a session lasts. |
| `KFW_SECURE_COOKIES` | `auto` | `auto` (over HTTPS), `true` or `false`. |
| `KFW_TRUST_PROXY` | `true` | Believe `X-Forwarded-For`, `-Proto` and `-Host` - only ever from 127.0.0.1, where Caddy is. |
| `KFW_LISTEN` | `http://127.0.0.1:8081/` | Where the server listens; Caddy is told the same. |
| `KFW_ADMIN_USER`, `KFW_ADMIN_PASSWORD(_FILE)` | | The first admin account, made at the first start (or `-AdminUser` of the installer). |
| `KFW_SITE_NAME` | | The site, shown under the name on the sign-in page (`CZECH DIVISION - Nyrany`). Empty, the page says what Kiosk Fleet is. |
| `KFW_RESTART_MESSAGE`, `KFW_RESTART_WARNING_SECONDS` | | What a restart shows on the kiosk by default. |
| `KFW_SCCM_SITE_SERVER` | | Added to the remote-control command the page shows. |
| `KFW_TEMPLATES_DIR` | the app's | The launchers' `EXAMPLE.json` (the config for a new screen), laid out like `KioskFleetWeb\templates\`. |
| `KFW_JOB_THREADS`, `KFW_REQUEST_THREADS` | `8`, `16` | Kiosk actions at once, requests at once. |
| `KFW_DEMO` | | `1`: a pretend fleet to try it on. |

The local-time columns of the events CSV follow the server's own time zone.

## What is in the data folder

| | |
|---|---|
| `users.json` | Accounts: names, roles and password hashes, laid out like the old `web-users.json`. |
| `sessions.json` | Signed-in sessions, by the SHA-256 of their cookie. |
| `audit.jsonl` | The audit log, one entry per line. |
| `kfw.env`, `share.cred` | Settings; the share account, if there is one. |
| `kiosk-list.*` | The kiosk list: as uploaded, or `kiosk-list.csv` once it has been edited in the app (the upload kept as `kiosk-list-before-edit.*`). |
| `MWST_FleetEvents.csv`, `.status.json` | The events, as the Power BI report reads them. |
| `logs\server.log`, `logs\collector.log`, `logs\caddy.log` | The server's, the collector's and Caddy's logs. |
| `logs\run\` | Each scan's output, kept for two weeks (*Activity → Reports*). |
| `logs\snapshots\` | Screenshots taken from the page, with what the launcher said about each (`.json`); the newest 10 of each screen, for 14 days. |
| `caddy\` | Caddy's config and the certificates it makes. |

Back up the folder; nothing else holds state.

## What is different from the PowerShell manager

- **There is no Windows or AD sign-in.** Everyone has an account of the app, and admins manage the accounts on the page.
- **No deploys.** Installing or rolling back the launchers is not done from here.
- **The collector does not read event logs across the network** (`-RemoteEventLog`). This was off by default, and the kiosks' agents copy the same records into their ledgers.
- **Remote control** and **Open share** run on your own PC. The page shows the command or the path to copy.
- **Only Public Documents.** Nothing goes to a kiosk but its Public Documents share: no WMI or CIM. Restart is the launcher's `restart.txt`.

More in [docs/MIGRATING.md](docs/MIGRATING.md).

## Development

```powershell
./Tests/Run-Tests.ps1                       # about 3 minutes; nothing touches the network (docs/TESTING.md)
./Start-KioskFleetWeb.ps1 -Demo -DataDir ./data -Listen http://localhost:8080/
```

It runs on Linux and macOS too, with PowerShell 7.4 (kiosks as folders, or shares mounted there); only the installer, DPAPI and `\\server\share` paths are Windows'.

| | |
|---|---|
| `KioskFleetWeb\Private\Server.ps1`, `Api.ps1` | The HTTP listener and its runspace pool; the page, sign-in, the API. |
| `KioskFleetWeb\Private\Auth.ps1`, `Store.ps1` | Roles, password hashes; accounts, sessions, audit. |
| `KioskFleetWeb\Private\Services.ps1` | The fleet as last read, kiosk jobs on worker threads, the scan as a child process, housekeeping. |
| `KioskFleetWeb\Private\Actions.ps1` | What can be done to a kiosk. |
| `KioskFleetWeb\Private\Collector.ps1` | The collector (`Collect-MWSTFleet.ps1` v6.2, as this app runs it). |
| `KioskFleetWeb\Private\Launchers.ps1`, `LauncherOptions.ps1` | Reading the launchers' status files and the watchdog's ledger; the settings a launcher reads. |
| `KioskFleetWeb\Private\FleetState.ps1`, `History.ps1`, `Screens.ps1` | From the events CSV to what the page draws. |
| `KioskFleetWeb\Private\KioskFs.ps1`, `Remote.ps1` | A kiosk's Public Documents (a share, or a folder); ping. |
| `KioskFleetWeb\Private\KioskList.ps1`, `ListEditor.ps1` | The kiosk list: .xlsx, .csv, .txt; editing it. |
| `KioskFleetWeb\Private\Csv.cs` | The CSV reader and writer, compiled at load: a PowerShell loop over 400 days of events is too slow. |
| `KioskFleetWeb\Private\Deploy.ps1` | The Caddyfile. |
| `KioskFleetWeb\web\` | The page: no framework, nothing from the internet, a strict content security policy. |
| `KioskFleetWeb\templates\` | Each launcher's `EXAMPLE.json`, the config editor's template for a new screen. |
| `KioskFleetWeb\Private\Demo.ps1` | The pretend fleet, for `-Demo` and the tests. |
