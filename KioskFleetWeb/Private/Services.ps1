# The moving parts behind the page: the fleet as last read, kiosk actions on
# worker threads, and the scan as a child process whose output the Activity
# view follows. All of it lives in $App, shared by every thread.

function New-KfwSyncTable { [hashtable]::Synchronized(@{}) }

function New-KfwApp($Settings) {
    Initialize-KfwDirs $Settings
    $App = [hashtable]::Synchronized(@{
        Settings      = $Settings
        Store         = Open-KfwStore $Settings.DataDir -Server
        LogPath       = Join-Path (Get-KfwLogDir $Settings) 'server.log'
        Stopping      = $false
        SetupToken    = $null
        Cache         = [hashtable]::Synchronized(@{ Stamp = ''; State = $null; ViewJson = 'null'; Rows = $null; RowsStamp = '' })
        CacheLock     = [object]::new()
        Jobs          = New-KfwSyncTable
        Busy          = New-KfwSyncTable
        Live          = New-KfwSyncTable
        Hold          = New-KfwSyncTable
        Snapshots     = New-KfwSyncTable
        ConfigWritten = New-KfwSyncTable
        JobsLock      = [object]::new()
        JobWork       = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        JobPool       = $null
        RequestPool   = $null
        Runner        = [hashtable]::Synchronized(@{
                Run = $null; Serial = 0; Log = ''; LogBase = 0; Last = $null; Progress = $null; AutoscanOn = $false; NextScanAt = $null
            })
        RunnerLock    = [object]::new()
        ListLock      = [object]::new()
        Housekeeping  = $null
        NextStateCheck = 0.0
        NextSweep     = 0.0
        NextPrune     = 0.0
        Demo          = $null
    })
    return $App
}

function Initialize-KfwApp($App, [switch]$Background) {
    Set-KfwContext $App
    Invoke-KfwBootstrap $App
    [void](Update-KfwFleetCache $App -Force)
    $App.JobPool = New-KfwRunspacePool $App.Settings.JobThreads
    if ($App.Settings.Autoscan) {
        $why = Enable-KfwAutoscan $App
        if ($why) { Write-KfwLog "auto-scan: $why" }
    }
    if ($Background) {
        $rs = [runspacefactory]::CreateRunspace($Host)
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript("Import-Module '$($script:ModuleManifest -replace "'", "''")'; Start-KfwHousekeeping `$args[0]").AddArgument($App)
        $App.Housekeeping = @{ PS = $ps; Handle = $ps.BeginInvoke(); Runspace = $rs }
    }
}

function Stop-KfwApp($App) {
    $App.Stopping = $true
    $hk = $App.Housekeeping
    if ($hk) {
        [void]$hk.Handle.AsyncWaitHandle.WaitOne(3000)
        try { $hk.PS.Dispose(); $hk.Runspace.Dispose() } catch { }
    }
    $r = $App.Runner.Run
    if ($r) { try { $r.Process.Kill($true) } catch { } }
    if ($App.Demo) { $App.Demo.Stop = $true }
    foreach ($p in $App.JobPool, $App.RequestPool) { if ($p) { try { $p.Close(); $p.Dispose() } catch { } } }
}

function Invoke-KfwBootstrap($App) {
    # The first admin: from KFW_ADMIN_USER / KFW_ADMIN_PASSWORD, or - with no
    # accounts at all - a one-time setup link printed in the log.
    $s = $App.Settings; $st = $App.Store
    if ($s.BootstrapAdmin -and $s.BootstrapPassword -and -not (Get-KfwUser $st $s.BootstrapAdmin)) {
        if (-not (Test-KfwUserName $s.BootstrapAdmin)) {
            Write-KfwLog "KFW_ADMIN_USER '$($s.BootstrapAdmin)' is not a usable account name; ignored."
        } elseif ((Get-KfwUserCount $st) -eq 0) {
            $problem = Get-KfwPasswordProblem $s.BootstrapPassword $s.BootstrapAdmin
            if ($problem) {
                Write-KfwLog "KFW_ADMIN_PASSWORD is not good enough ($problem); no account was made from it."
            } else {
                Add-KfwUser $st $s.BootstrapAdmin 'admin' $s.BootstrapPassword
                Write-KfwAudit $st -Action 'user-add' -Target $s.BootstrapAdmin -Result 'ok' -Detail 'admin, from KFW_ADMIN_USER'
                Write-KfwLog "Made the admin account '$($s.BootstrapAdmin)' from KFW_ADMIN_USER."
            }
        }
    }
    if ((Get-KfwUserCount $st) -eq 0) {
        $App.SetupToken = New-KfwToken 24
        # The link is also kept in a file only administrators can read, for
        # a server started by the scheduled task, whose console nobody sees.
        try { [IO.File]::WriteAllText((Join-Path $s.DataDir 'setup-link.txt'), "/setup?token=$($App.SetupToken)`r`n") } catch { }
        Write-KfwLog ('=' * 72)
        Write-KfwLog 'No accounts yet. Make the first admin account here (the link works once):'
        Write-KfwLog "    https://<this server>/setup?token=$($App.SetupToken)"
        Write-KfwLog ('=' * 72)
    }
}

function Clear-KfwSetupToken($App) {
    $App.SetupToken = $null
    try { [IO.File]::Delete((Join-Path $App.Settings.DataDir 'setup-link.txt')) } catch { }
}

function Start-KfwHousekeeping($App) {
    Set-KfwContext $App
    while (-not $App.Stopping) {
        try { Invoke-KfwTick $App } catch { Write-KfwLog "housekeeping: $($_.Exception.Message) $($_.ScriptStackTrace -replace "`n", ' <- ')" }
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-KfwTick($App) {
    $now = Get-KfwEpoch
    $s = $App.Settings
    Update-KfwRunner $App
    if ($now -ge $App.NextStateCheck) {
        [void](Update-KfwFleetCache $App)
        $App.NextStateCheck = $now + $s.RefreshSeconds
    }
    $r = $App.Runner
    if ($r.AutoscanOn -and $null -eq $r.Run -and $r.NextScanAt -and $now -ge $r.NextScanAt) {
        $why = Start-KfwScan $App -Auto
        if ($why) { $r.NextScanAt = $now + $s.AutoscanMinutes * 60 }
    }
    $w = $null
    $keep = [Collections.Generic.List[object]]::new()
    while ($App.JobWork.TryDequeue([ref]$w)) { if (-not (Complete-KfwBackground $w)) { $keep.Add($w) } }
    foreach ($w in $keep) { $App.JobWork.Enqueue($w) }
    if ($now -ge $App.NextSweep) {
        $App.NextSweep = $now + 30
        Clear-KfwOldSessions $App.Store $s.IdleMinutes $s.SessionHours
        Clear-KfwOldFailures $App.Store
        Clear-KfwOldJobs $App
    }
    if ($now -ge $App.NextPrune) {
        $App.NextPrune = $now + 3600
        [void](Remove-KfwOldScreens (Get-KfwSnapshotDir $s))
    }
}

# --- the fleet as last read ----------------------------------------------------------
function Get-KfwCsvStamp([string]$Path) {
    $parts = foreach ($p in $Path, [IO.Path]::ChangeExtension($Path, '.status.json')) { Get-KfwFileStamp $p }
    return $parts -join ';'
}

function Update-KfwFleetCache($App, [switch]$Force) {
    # The fleet, read again when the CSV or its status file changed.
    $path = Get-KfwEventsCsv $App.Settings
    $stamp = Get-KfwCsvStamp $path
    $c = $App.Cache
    if (-not $Force -and $stamp -eq $c.Stamp -and $null -ne $c.State) { return $false }
    [Threading.Monitor]::Enter($App.CacheLock)
    try {
        $rows = Get-KfwEventRows $App $path
        $state = Read-KfwFleetState $path $rows
        $view = ConvertTo-KfwJson (Get-KfwFleetView $state)
        $c.Stamp = $stamp; $c.State = $state; $c.ViewJson = $view
    } finally { [Threading.Monitor]::Exit($App.CacheLock) }
    return $true
}

function Get-KfwEventRows($App, [string]$Path) {
    # The events CSV's rows, parsed once per change of the file: the fleet
    # view and every History read come from the same copy.
    $c = $App.Cache
    $stamp = Get-KfwFileStamp $Path
    if ($null -ne $c.Rows -and $c.RowsStamp -eq $stamp) { return , $c.Rows }
    $rows = Read-KfwCsvRows $Path
    $c.Rows = $rows; $c.RowsStamp = $stamp
    return , $rows
}

function Get-KfwCachedKiosk($App, [string]$HostName) {
    $st = $App.Cache.State
    if (-not $st -or -not $st.Ok) { return $null }
    foreach ($k in $st.Hosts) { if ([string]::Equals($k.Host, $HostName, [StringComparison]::OrdinalIgnoreCase)) { return $k } }
    return $null
}

# --- kiosk jobs ------------------------------------------------------------------------
# Anything that touches a kiosk takes seconds, or half a minute when it is
# off: it runs on a worker thread and the page asks for it by id. One thing
# at a time per kiosk, for everyone.

function New-KfwActionContext([string]$Target, [string]$Who = 'Kiosk Fleet Web') {
    [hashtable]::Synchronized(@{
        Target = $Target; Who = $Who; Kind = 'ALL'; Screen = ''; Params = @{}; Secret = $null
        Lines = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new())
    })
}

function Start-KfwJob($App, [string]$Action, [string]$Label, [string]$Target, $Ctx, $Session, [string]$Ip, [string]$AuditAction) {
    $job = [hashtable]::Synchronized(@{
        id = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')).Substring(0, 22)
        action = $Action; label = $Label; target = $Target
        user = if ($Session) { $Session.user } else { '' }; role = if ($Session) { $Session.role } else { '' }
        ip = $Ip; audit_action = $AuditAction; ctx = $Ctx; started = Get-KfwEpoch; finished = $null
        done = $false; ok = $null; detail = ''; result = $null; lines = $Ctx.Lines
    })
    [Threading.Monitor]::Enter($App.JobsLock)
    try {
        $App.Jobs[$job.id] = $job
        if ($Target) { $App.Busy[$Target] = $Label }
    } finally { [Threading.Monitor]::Exit($App.JobsLock) }
    $App.JobWork.Enqueue((Invoke-KfwInBackground $App.JobPool 'Invoke-KfwJob' @($App, $job)))
    return $job
}

function Test-KfwBusy($App, [string]$Target) {
    # The busy check and the job start under one lock, so two clicks at once
    # do not both get through.
    [Threading.Monitor]::Enter($App.JobsLock)
    try { return $App.Busy.ContainsKey($Target) } finally { [Threading.Monitor]::Exit($App.JobsLock) }
}

function Invoke-KfwJob($App, $Job) {
    Set-KfwContext $App
    try {
        $r = Invoke-KfwAction $Job.action $Job.ctx
    } catch {
        $r = @{ Ok = $false; Detail = "$($_.Exception.GetType().Name): $($_.Exception.Message)" }
    }
    $Job.result = $r
    $Job.ok = [bool]$r.Ok
    $Job.detail = [string]$r.Detail
    $Job.finished = Get-KfwEpoch
    try { Complete-KfwJobEffects $App $Job } catch { Write-KfwLog "job $($Job.action): $($_.Exception.Message)" }
    [Threading.Monitor]::Enter($App.JobsLock)
    try {
        $Job.done = $true
        $App.Busy.Remove($Job.target)
    } finally { [Threading.Monitor]::Exit($App.JobsLock) }
    if ($Job.audit_action) {
        $result = if ($Job.ok) { if ($r.Waiting) { 'waiting' } else { 'ok' } } else { 'failed' }
        Write-KfwAudit $App.Store -User $Job.user -Role $Job.role -Ip $Job.ip -Action $Job.audit_action -Target $Job.target -Result $result -Detail $Job.detail
    }
}

function Complete-KfwJobEffects($App, $Job) {
    $r = $Job.result; $t = $Job.target
    if (-not $r.Ok) { return }
    $clock = [datetime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    switch ($Job.action) {
        'live' {
            $App.Live[$t] = [ordered]@{ At = $clock; Lines = @($r.Lines) }
            $App.Hold[$t] = [bool]$r.Hold
        }
        'control' {
            if ($Job.ctx.Params.file -eq 'hold.txt') { $App.Hold[$t] = -not $Job.ctx.Params['remove'] }
        }
        'snapshot' {
            if ($r.File) { $App.Snapshots[$t] = [ordered]@{ File = $r.File; Caption = "$($r.Instance) $clock  |  $($r.State)  |  $($r.Url)" } }
        }
        'config-write' {
            $App.ConfigWritten[$t] = $true
            $App.Live.Remove($t)
        }
    }
}

function Clear-KfwOldJobs($App) {
    $cutoff = (Get-KfwEpoch) - 15 * 60
    [Threading.Monitor]::Enter($App.JobsLock)
    try {
        foreach ($id in @($App.Jobs.Keys)) {
            $j = $App.Jobs[$id]
            if ($j.done -and [double]$j.finished -lt $cutoff) { $App.Jobs.Remove($id) }
        }
    } finally { [Threading.Monitor]::Exit($App.JobsLock) }
}

function ConvertTo-KfwJobView($Job) {
    $r = if ($Job.result) { $Job.result } else { @{} }
    $extra = $null
    if ($Job.done -and $Job.action -eq 'test' -and $r.Lines) {
        $extra = [ordered]@{ lines = @($r.Lines) }
    } elseif ($Job.done -and $Job.result) {
        switch ($Job.action) {
            'live' { $extra = [ordered]@{ lines = @($r.Lines); hold = [bool]$r.Hold } }
            'log' { $extra = [ordered]@{ lines = @($r.Lines); path = [string]$r.Path } }
            'snapshot' { $extra = [ordered]@{ file = [string]$r.File; instance = [string]$r.Instance; state = [string]$r.State; url = [string]$r.Url } }
            'config-read' {
                $extra = [ordered]@{
                    kind = $r.Kind; isNew = [bool]$r.IsNew; instance = $r.Instance; instances = @($r.Instances); password = $r.Password
                    taken = if ($r.Taken) { $r.Taken } else { @{} }; fields = @($r.Fields); launcherOptions = [int]$r.LauncherOptions
                }
            }
            'config-write' { $extra = [ordered]@{ isNew = [bool]$r.IsNew; path = [string]$r.Path; password = [string]$r.Password } }
            'message' { $extra = [ordered]@{ status = [string]$r.Status } }
        }
    }
    [ordered]@{
        id = $Job.id; action = $Job.action; target = $Job.target; done = [bool]$Job.done; ok = $Job.ok
        waiting = [bool]$r.Waiting; detail = [string]$Job.detail; lines = @($Job.lines.ToArray()); result = $extra
    }
}

# --- the scan, as a child process ---------------------------------------------------------
# One at a time for everyone. Its output is kept for the Activity view and in
# logs\run\ for later.

$script:RunLogLimit = 2MB

function Add-KfwRunLog($App, [string]$Text) {
    $r = $App.Runner
    $r.Log += $Text
    if ($r.Log.Length -gt $script:RunLogLimit) {
        $drop = $r.Log.Length - [int]($script:RunLogLimit * 0.75)
        $r.Log = $r.Log.Substring($drop)
        $r.LogBase += $drop
    }
}

function Read-KfwRunLog($App, [long]$From) {
    [Threading.Monitor]::Enter($App.RunnerLock)
    try {
        $r = $App.Runner
        $start = [Math]::Max(0, $From - $r.LogBase)
        $text = if ($start -lt $r.Log.Length) { $r.Log.Substring($start) } else { '' }
        return [ordered]@{ from = [Math]::Max($From, $r.LogBase); next = $r.LogBase + $r.Log.Length; text = $text; running = $null -ne $r.Run; last = $r.Last }
    } finally { [Threading.Monitor]::Exit($App.RunnerLock) }
}

function Get-KfwProgressFile($App) { Join-Path (Get-KfwLogDir $App.Settings) 'autoscan.progress.json' }

function Get-KfwPwshPath {
    $p = [Environment]::ProcessPath
    if ($p -and [IO.Path]::GetFileNameWithoutExtension($p) -eq 'pwsh') { return $p }
    return (Join-Path $PSHOME ($(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
}

function Start-KfwScan($App, [switch]$Auto, $Session) {
    $s = $App.Settings
    if (-not (Resolve-KfwKioskList $s)) { return 'there is no kiosk list yet - upload one in Settings' }
    $problem = Get-KfwShareProblem $s
    if ($Auto -and $problem) {
        # Every kiosk would come back NO_ACCESS, and those false outages
        # would be written into the history.
        return "auto-scan cannot open the kiosks: $problem"
    }
    $manifest = $script:ModuleManifest -replace "'", "''"
    $progress = (Get-KfwProgressFile $App) -replace "'", "''"
    $cmd = "Import-Module '$manifest'; exit (Invoke-KfwScan -ProgressFile '$progress')"
    return Start-KfwRun $App 'Fleet scan' 'scan' @('-NoProfile', '-NonInteractive', '-Command', $cmd) -Quiet:$Auto -Session $Session
}

function Start-KfwRun($App, [string]$Title, [string]$Kind, [string[]]$Arguments, [switch]$Quiet, $Session, [string]$Program) {
    [Threading.Monitor]::Enter($App.RunnerLock)
    try {
        $r = $App.Runner
        if ($r.Run) { return "$($r.Run.Title) is still running" }
        $runDir = Get-KfwRunDir $App.Settings
        [void][IO.Directory]::CreateDirectory($runDir)
        $cutoff = [datetime]::UtcNow.AddDays(-14)
        foreach ($old in [IO.DirectoryInfo]::new($runDir).GetFiles()) {
            try { if ($old.LastWriteTimeUtc -lt $cutoff) { $old.Delete() } } catch { }
        }
        $now = [datetime]::Now
        $stamp = $now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $out = Join-Path $runDir "$Kind-$stamp.out.txt"
        $who = if ($Session) { "$($Session.user) ($($Session.role))" } else { 'auto-scan' }
        [IO.File]::WriteAllText($out, "# Kiosk Fleet Web, $($now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)) - $Title - for $who`n")

        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = if ($Program) { $Program } else { Get-KfwPwshPath }
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # The child reads the same settings as this process, whatever set them.
        $psi.Environment['KFW_SETTINGS_JSON'] = ConvertTo-KfwSettingsJson $App.Settings
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        try {
            $proc = [Diagnostics.Process]::Start($psi)
        } catch {
            return "could not start it: $($_.Exception.Message)"
        }
        # What the child prints goes into its output file too; read in the
        # background so a full pipe never stops it.
        $copy = { param($reader, $path) try { while ($null -ne ($line = $reader.ReadLine())) { [IO.File]::AppendAllText($path, $line + "`n") } } catch { } }
        $ps1 = [powershell]::Create().AddScript($copy).AddArgument($proc.StandardOutput).AddArgument($out)
        $ps2 = [powershell]::Create().AddScript($copy).AddArgument($proc.StandardError).AddArgument($out)
        $h1 = $ps1.BeginInvoke(); $h2 = $ps2.BeginInvoke()

        $r.Serial++
        $r.Run = [hashtable]::Synchronized(@{
            Serial = $r.Serial; Title = $Title; Kind = $Kind; Process = $proc; Pid = $proc.Id; Out = $out; Started = Get-KfwEpoch
            Quiet = [bool]$Quiet; Who = $who; User = if ($Session) { $Session.user } else { '' }; Role = if ($Session) { $Session.role } else { '' }
            Pos = 0L; Readers = @(@{ PS = $ps1; Handle = $h1 }, @{ PS = $ps2; Handle = $h2 })
        })
        if ($Kind -eq 'scan') {
            $r.Progress = $null
            try { [IO.File]::Delete((Get-KfwProgressFile $App)) } catch { }
        }
        if (-not $Quiet) { Add-KfwRunLog $App "`n===== $Title  $($now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture))  ($who) =====`n" }
        return $null
    } finally { [Threading.Monitor]::Exit($App.RunnerLock) }
}

function Stop-KfwRun($App, $Session) {
    [Threading.Monitor]::Enter($App.RunnerLock)
    try {
        $r = $App.Runner.Run
        if (-not $r) { return 'nothing is running' }
        try { $r.Process.Kill($true) } catch { return "could not stop it: $($_.Exception.Message)" }
        Add-KfwRunLog $App "`n===== stopped by $($Session.user) =====`n"
        return $null
    } finally { [Threading.Monitor]::Exit($App.RunnerLock) }
}

function Read-KfwRunOutput($Run) {
    try {
        $fs = [IO.FileStream]::new($Run.Out, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            if ($fs.Length -le $Run.Pos) { return '' }
            [void]$fs.Seek($Run.Pos, [IO.SeekOrigin]::Begin)
            $buf = [byte[]]::new($fs.Length - $Run.Pos)
            $n = $fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
    } catch { return '' }
    # Only whole UTF-8 characters: the rest is read next time.
    $cut = $n
    while ($cut -gt 0 -and ($buf[$cut - 1] -band 0xC0) -eq 0x80) { $cut-- }
    if ($cut -gt 0 -and $buf[$cut - 1] -ge 0xC0) { $cut-- } else { $cut = $n }
    $Run.Pos += $cut
    return [Text.Encoding]::UTF8.GetString($buf, 0, $cut)
}

function Update-KfwRunner($App) {
    $finished = $null
    [Threading.Monitor]::Enter($App.RunnerLock)
    try {
        $r = $App.Runner
        $run = $r.Run
        if (-not $run) { return }
        $text = Read-KfwRunOutput $run
        if ($text -and -not $run.Quiet) { Add-KfwRunLog $App $text }
        if ($run.Kind -eq 'scan') {
            try {
                $p = ConvertFrom-Json ([IO.File]::ReadAllText((Get-KfwProgressFile $App))) -AsHashtable
                if ($p.Pid -eq $run.Pid) { $r.Progress = $p }
            } catch { }
        }
        if (-not $run.Process.HasExited) { return }
        foreach ($w in $run.Readers) { [void]$w.Handle.AsyncWaitHandle.WaitOne(2000); try { $w.PS.Dispose() } catch { } }
        $text = Read-KfwRunOutput $run
        if ($text -and -not $run.Quiet) { Add-KfwRunLog $App $text }
        $code = $run.Process.ExitCode
        $secs = [int]((Get-KfwEpoch) - $run.Started)
        if (-not $run.Quiet) { Add-KfwRunLog $App "`n===== $($run.Title): finished with code $code after ${secs}s =====`n" }
        $r.Last = [ordered]@{ Title = $run.Title; Kind = $run.Kind; Code = $code; Seconds = $secs; Finished = [datetime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); Who = $run.Who }
        $r.Run = $null
        $run.Process.Dispose()
        if ($run.Kind -eq 'scan') {
            $r.Progress = $null
            $r.NextScanAt = (Get-KfwEpoch) + $App.Settings.AutoscanMinutes * 60
        }
        $finished = @{ Run = $run; Code = $code; Secs = $secs }
    } finally { [Threading.Monitor]::Exit($App.RunnerLock) }
    if ($finished) {
        $run = $finished.Run
        $result = if ($finished.Code -eq 0) { 'ok' } else { 'failed' }
        Write-KfwAudit $App.Store -User $run.User -Role $run.Role -Action "$($run.Kind)-finished" -Target $run.Title -Result $result -Detail "exit code $($finished.Code) after $($finished.Secs)s"
        if ($run.Kind -eq 'scan') { [void](Update-KfwFleetCache $App -Force) }
    }
}

function Enable-KfwAutoscan($App) {
    $s = $App.Settings
    $problem = Get-KfwShareProblem $s
    if ($problem) { return "auto-scan cannot open the kiosks: $problem" }
    $App.Runner.AutoscanOn = $true
    $next = Get-KfwEpoch
    $f = Get-KfwFreshness $App.Cache.State $s.StaleMinutes
    if ($null -ne $f.minutes) { $next = [Math]::Max($next, (Get-KfwEpoch) + ($s.AutoscanMinutes - $f.minutes) * 60) }
    $App.Runner.NextScanAt = $next
    return $null
}

function Get-KfwRunStatus($App) {
    $run = $App.Runner.Run
    if (-not $run) { return $null }
    $el = [int]((Get-KfwEpoch) - $run.Started)
    $scan = $null
    if ($run.Kind -eq 'scan') {
        $p = $App.Runner.Progress
        $pct = 0; $text = 'starting'
        if ($p -and $p.Total) {
            if ($p.Phase -eq 'saving') { $pct = 100; $text = 'saving' }
            else {
                $pct = [int][Math]::Floor(100 * [Math]::Max(0, [int]$p.Index - 1) / [double]$p.Total)
                $text = "$($p.Index)/$($p.Total) $($p.Host)"
            }
        }
        $scan = [ordered]@{ pct = $pct; text = $text }
    }
    [ordered]@{ serial = $run.Serial; title = $run.Title; kind = $run.Kind; who = $run.Who; quiet = $run.Quiet; elapsed = ('{0}:{1:00}' -f [Math]::Floor($el / 60), ($el % 60)); scan = $scan }
}

function Get-KfwReports($App) {
    $d = Get-KfwRunDir $App.Settings
    if (-not [IO.Directory]::Exists($d)) { return , @() }
    $files = [IO.DirectoryInfo]::new($d).GetFiles() | Where-Object { $_.Name.EndsWith('.out.txt') -or $_.Name.EndsWith('.csv') } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 60
    return , @($files)
}

function Get-KfwNextScanMinutes($App) {
    $r = $App.Runner
    if (-not $r.AutoscanOn -or -not $r.NextScanAt) { return 0 }
    return [int][Math]::Max(0, [Math]::Ceiling(($r.NextScanAt - (Get-KfwEpoch)) / 60))
}

function Get-KfwCredentialNote($App) {
    $s = $App.Settings
    return Get-KfwShareProblem $s
}
