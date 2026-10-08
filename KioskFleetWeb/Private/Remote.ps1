# Reaching a kiosk over the network: is it there?
#
# ICMP first, two attempts - one dropped packet should not mark a kiosk
# offline - then SMB on 445, because a kiosk whose firewall drops ping but
# serves its share is reachable for every purpose that matters here.
#
# Nothing else goes to a kiosk but its share: no WMI, no CIM, no DCOM.
# Restarts are a control file (restart.txt) the launcher acts on.

function Test-KfwTcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 1000) {
    $c = [Net.Sockets.TcpClient]::new()
    try {
        $t = $c.ConnectAsync($HostName, $Port)
        return ($t.Wait($TimeoutMs) -and $c.Connected)
    } catch {
        return $false
    } finally { $c.Dispose() }
}

function Test-KfwReachable([string]$HostName, $S, [int]$TimeoutMs = 0) {
    # @{ Ok; Method; Error }
    if (-not (Test-KfwUsesUnc $S) -or $S.OfflineOk) { return @{ Ok = $true; Method = 'local'; Error = $null } }
    if (-not $TimeoutMs) { $TimeoutMs = $S.PingTimeoutMs }
    try {
        [void][Net.Dns]::GetHostAddresses($HostName)
    } catch {
        # The name does not resolve, so neither a second ping nor a port probe will help.
        return @{ Ok = $false; Method = $null; Error = "Name/ping failure: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
    }
    $last = $null
    $ping = [Net.NetworkInformation.Ping]::new()
    try {
        foreach ($i in 1, 2) {
            try {
                $r = $ping.Send($HostName, $TimeoutMs)
                if ($r.Status -eq [Net.NetworkInformation.IPStatus]::Success) { return @{ Ok = $true; Method = 'ping'; Error = $null } }
                $last = if ($r.Status -eq [Net.NetworkInformation.IPStatus]::TimedOut) { 'No ping reply (timed out)' } else { "No ping reply ($($r.Status))" }
            } catch {
                $last = "No ping reply: $($_.Exception.InnerException.Message ?? $_.Exception.Message)"
            }
        }
    } finally { $ping.Dispose() }
    if (Test-KfwTcpPort $HostName 445 $TimeoutMs) { return @{ Ok = $true; Method = 'smb'; Error = $null } }
    return @{ Ok = $false; Method = $null; Error = $last }
}
