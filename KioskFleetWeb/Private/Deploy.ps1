# What Caddy is told: HTTPS, the page from the web folder, and /api and
# /healthz to this server on 127.0.0.1. Install-KioskFleetWeb.ps1 writes it;
# the tests run Caddy with it too.

function Get-KfwCaddyfile {
    [CmdletBinding()]
    param(
        # https://kiosks.contoso.local, or http://... with -Tls off.
        [Parameter(Mandatory)][string]$SiteAddress,
        [Parameter(Mandatory)][string]$WebDir,
        # Caddy's own files: the certificates it makes, its locks.
        [Parameter(Mandatory)][string]$Storage,
        # internal (Caddy's own CA), off (plain HTTP), or a certificate.
        [ValidateSet('internal', 'off', 'files')][string]$Tls = 'internal',
        [string]$CertificateFile,
        [string]$KeyFile,
        [string]$Backend = '127.0.0.1:8081',
        [string]$LogFile
    )
    $q = { param([string]$p) '"' + ($p -replace '\\', '/') + '"' }
    $tlsLine = switch ($Tls) {
        'internal' { "`ttls internal" }
        'files' { "`ttls $(& $q $CertificateFile) $(& $q $KeyFile)" }
        default { '' }
    }
    $log = if ($LogFile) { "`tlog {`n`t`toutput file $(& $q $LogFile) {`n`t`t`troll_size 10MiB`n`t`t`troll_keep 5`n`t`t}`n`t}" } else { '' }
    $csp = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    $hsts = if ($Tls -ne 'off') { "`t`tStrict-Transport-Security `"max-age=31536000`"`n" } else { '' }
    return @"
# Kiosk Fleet Web behind Caddy. Written by Install-KioskFleetWeb.ps1; run it
# again to change it rather than editing this file.
{
	admin off
	storage file_system $(& $q $Storage)
	skip_install_trust
}

$SiteAddress {
$tlsLine
$log
	encode gzip
	header {
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy no-referrer
		Content-Security-Policy "$csp"
$hsts		-Server
	}

	# The page's calls, to the server. It trusts X-Forwarded-For/-Proto/-Host
	# from 127.0.0.1 only, and Caddy sets them.
	@app path /api/* /healthz
	handle @app {
		request_body {
			max_size 11MB
		}
		reverse_proxy $Backend {
			header_up Host {upstream_hostport}
		}
	}

	# The page itself: four files, never cached stale.
	handle {
		root * $(& $q $WebDir)
		rewrite /setup /index.html
		header Cache-Control no-cache
		file_server
	}
}
"@
}
