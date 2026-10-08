# Testing

```powershell
./Tests/Run-Tests.ps1                      # everything, about 3 minutes
./Tests/Run-Tests.ps1 -Filter Collector    # one file
./Tests/Run-Tests.ps1 -Filter Test-State   # one test (wildcards work)
```

PowerShell 7.4 or later, on Windows, Linux or macOS. Nothing touches a real kiosk or the network beyond 127.0.0.1. Kiosks are folders standing in for their Public Documents (`KioskFleetWeb\Private\Demo.ps1`), with a thread playing their launchers and watchdog: it takes control files, answers screenshots, stores `password.seed`, and acknowledges messages. Each test that needs the server starts it - the real one, `Start-KfwServer` with its HttpListener - in a process of its own on a free port, and talks to it over HTTP with a cookie jar per person signed in.

- **The web app** (`Tests/Web.Tests.ps1`): signing in, lockout, CSRF and origin checks, first-admin setup, roles (an operator is refused every admin action, and each refusal is audited), the fleet served to the page, every kiosk action, the config editor (existing and new kiosks, one launcher per screen), the password hand-over (never in the audit log or any file of the server), messages, restarts, busy kiosks, accounts (must-change, role changes and disabling taking effect at once, the last admin kept), importing PowerShell accounts from the command line while the server runs, kiosk-list upload, settings from `kfw.env`, and the audit log's search and CSV export.
- **The collector** (`Tests/Collector.Tests.ps1`): reboot reconciliation (one boot is one reboot, failed triggers, unexplained boots, unexpected shutdowns), a whole scan of folder kiosks (statuses, the ledger with copied Windows events, a row mid-append, the status file, the CSV's exact format, a second scan adding nothing, a kiosk going stale), a CSV saved from Excel left alone, the published copy restored from the local one, .xlsx/.txt kiosk lists, a scan started from the page, and stopping one.
- **History, the kiosk list and group actions** (`Tests/Features.Tests.ps1`): the status timeline (gaps shown as no data), reboots and uptime; adding, changing, deactivating and removing kiosks in the list, from .txt and .xlsx; actions on many kiosks, with ineligible and busy ones skipped.
- **Screens** (`Tests/Screens.Tests.ps1`) and **the launchers' settings** (`Tests/LauncherOptions.Tests.ps1`).
- **The platform** (`Tests/Platform.Tests.ps1`): on Windows, the share account kept with DPAPI and `\\localhost\C$` opened by Windows; anywhere Caddy is (`KFW_TEST_CADDY`, or `caddy` on the PATH), the server behind it - the page and its headers from Caddy, a `Secure` cookie, origin checks through the proxy. Skipped where they cannot run, and said so.

## The same as the Python version

```powershell
./Tests/Parity/Compare-WithPython.ps1 -PythonRepo ../kiosk-fleet-web
```

Runs this collector and `kfw/collector.py` on the same fleet at the same moment (two scans each, so the merge is compared too), on a fleet with everything in it: rolled ledgers, copied 1074/6005/6008 records, failed triggers, the loop guard, an old watchdog, two screens, stale and wrong-account launchers. The events CSV must come out byte for byte the same, but for the run's own row; the status file the same; and so must the fleet the page is sent, every kiosk's history over 7, 28 and 90 days, and the kiosk list view. It needs `python3` and a checkout of kiosk-fleet-web.

## Installed

`.github/workflows/ci.yml` runs the tests on Linux and Windows, and on Windows also installs the app on a pretend fleet with `Install-KioskFleetWeb.ps1 -Demo`, then `Tests/Test-Installed.ps1` uses it through Caddy over HTTPS (the task and service run, the page, signing in, the fleet, a kiosk action, a scan, the audit log), and uninstalls it. The same script checks a real installation:

```powershell
./Tests/Test-Installed.ps1 -SiteAddress https://kiosks.contoso.local -User admin -Password '...'
```

Before restarting a real kiosk from here, try **Restart...** on one: that Windows then restarts is the launcher's part.
