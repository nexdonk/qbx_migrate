<#
.SYNOPSIS
    Local control panel for qbx_migrate. Started by run.bat; opens in your browser.

.DESCRIPTION
    Serves panel/index.html on http://localhost:<port>/ and does two jobs for it:

      - runs tools\Convert-QbxResources.ps1 (code audit / rewrite / restore) on this machine
      - forwards `qbxmigrate` commands to the running FiveM server through server/panel.lua

    Listens on localhost only. Close this window (or Ctrl+C) to stop it.
#>
[CmdletBinding()]
param(
    [int] $Port = 7480,
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'

# Everything below uses .NET IO or -LiteralPath: this folder usually lives under
# resources\[qbx]\, and [qbx] is a wildcard to most PowerShell path parameters.
$PanelDir     = $PSScriptRoot
$Root         = [System.IO.Path]::GetDirectoryName($PanelDir)
$ToolScript   = [System.IO.Path]::Combine($Root, 'tools', 'Convert-QbxResources.ps1')
$ToolsDir     = [System.IO.Path]::Combine($Root, 'tools')
$OutputDir    = [System.IO.Path]::Combine($Root, 'output')
$BackupsDir   = [System.IO.Path]::Combine($Root, 'backups')
$TokenFile    = [System.IO.Path]::Combine($Root, 'panel_token.txt')
$SettingsFile = [System.IO.Path]::Combine($PanelDir, 'settings.json')
$IndexFile    = [System.IO.Path]::Combine($PanelDir, 'index.html')
$Utf8         = New-Object System.Text.UTF8Encoding($false)
$PsExe        = (Get-Process -Id $PID).Path

# =====================================================================================
# SETTINGS
# =====================================================================================

function Get-DefaultSettings {
    # If the kit sits inside a server's resources folder, point at that server.
    $resources = ''
    $cfg = ''
    $dir = $Root
    while ($dir) {
        if ([System.IO.Path]::GetFileName($dir) -eq 'resources') {
            $resources = $dir
            $candidate = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($dir), 'server.cfg')
            if ([System.IO.File]::Exists($candidate)) { $cfg = $candidate }
            break
        }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
    return [ordered]@{
        resourcesPath = $resources
        serverCfg     = $cfg
        excludeDir    = ''
        fivemUrl      = 'http://127.0.0.1:30120'
        token         = ''
    }
}

function Get-Settings {
    $s = Get-DefaultSettings
    if ([System.IO.File]::Exists($SettingsFile)) {
        try {
            $saved = [System.IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json
            foreach ($key in @($s.Keys)) {
                if ($null -ne $saved.$key) { $s[$key] = [string] $saved.$key }
            }
        }
        catch { Write-Warning "settings.json unreadable, using defaults: $_" }
    }
    return $s
}

function Save-Settings($s) {
    [System.IO.File]::WriteAllText($SettingsFile, ($s | ConvertTo-Json), $Utf8)
}

function Get-Token($s) {
    if ($s.token) { return $s.token.Trim() }
    if ([System.IO.File]::Exists($TokenFile)) { return [System.IO.File]::ReadAllText($TokenFile).Trim() }
    return ''
}

# =====================================================================================
# LOCAL JOBS (code audit / rewrite / restore - one at a time)
# =====================================================================================

$script:LocalJob = $null

function Quote([string] $s) { "'" + $s.Replace("'", "''") + "'" }

function Start-LocalJob([string] $title, [string] $command, [string] $reportPath) {
    if ($script:LocalJob -and -not $script:LocalJob.Process.HasExited) {
        throw 'A local job is already running.'
    }
    $log = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "qbxm_panel_$PID.log")
    $err = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "qbxm_panel_$PID.err")
    # A wrapper script rather than -EncodedCommand, which turns stderr into CLIXML.
    # BOM so Windows PowerShell reads non-ASCII paths in it correctly.
    $wrapper = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "qbxm_panel_$PID.ps1")
    [System.IO.File]::WriteAllText($wrapper, "`$ProgressPreference = 'SilentlyContinue'`r`n$command`r`n",
        (New-Object System.Text.UTF8Encoding($true)))
    $proc = Start-Process -FilePath $PsExe -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$wrapper`"") `
        -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $proc.Handle  # caches the handle so ExitCode is readable after exit
    $script:LocalJob = @{
        Id = [guid]::NewGuid().ToString('n').Substring(0, 8)
        Title = $title; Process = $proc; Log = $log; Err = $err
        ReportPath = $reportPath; Started = (Get-Date)
    }
    return $script:LocalJob.Id
}

function Read-Shared([string] $path) {
    if (-not [System.IO.File]::Exists($path)) { return '' }
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}

function Get-LocalJobView([int] $from) {
    $job = $script:LocalJob
    if (-not $job) { return @{ status = 'none' } }
    $done = $job.Process.HasExited
    # Read stderr only after exit: it is written in one go and would otherwise interleave badly.
    $text = Read-Shared $job.Log
    if ($done) {
        $errText = (Read-Shared $job.Err).Trim()
        if ($errText) { $text += "`n[stderr]`n$errText" }
    }
    $lines = [System.Collections.Generic.List[string]] @($text -split "`r?`n")
    # The last element is '' after a newline, or a half-written line while running.
    if ($lines.Count -and ($lines[$lines.Count - 1] -eq '' -or -not $done)) { $lines.RemoveAt($lines.Count - 1) }
    $slice = @()
    if ($from -lt $lines.Count) { $slice = @($lines.GetRange($from, $lines.Count - $from)) }
    $view = @{
        id = $job.Id; title = $job.Title; lines = $slice; next = $lines.Count
        status = if (-not $done) { 'running' } elseif ($job.Process.ExitCode -eq 0) { 'done' } else { 'failed' }
    }
    if ($done -and $job.ReportPath -and [System.IO.File]::Exists($job.ReportPath)) {
        $view.report = [System.IO.File]::ReadAllText($job.ReportPath)
        $view.reportFolder = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($job.ReportPath))
    }
    return $view
}

function Start-Audit($s, [bool] $apply, [bool] $aggressive) {
    if (-not $s.resourcesPath -or -not [System.IO.Directory]::Exists($s.resourcesPath)) {
        throw "Resources folder not found: '$($s.resourcesPath)'. Set it under Settings."
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $out = [System.IO.Path]::Combine($ToolsDir, "qbx_migration_$stamp")
    [void] [System.IO.Directory]::CreateDirectory($out)
    $cmd = "& $(Quote $ToolScript) -ResourcesPath $(Quote $s.resourcesPath.TrimEnd('\')) -OutputPath $(Quote $out)"
    if ($s.serverCfg) { $cmd += " -ServerCfg $(Quote $s.serverCfg)" }
    $ex = @($s.excludeDir -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ex.Count) { $cmd += ' -ExcludeDir ' + (($ex | ForEach-Object { Quote $_ }) -join ',') }
    if ($apply) { $cmd += ' -Apply' }
    if ($aggressive) { $cmd += ' -Aggressive' }
    $title = if ($apply) { 'Code rewrite (apply)' } else { 'Code audit (dry run)' }
    if ($aggressive) { $title += ' + aggressive' }
    return Start-LocalJob $title $cmd ([System.IO.Path]::Combine($out, 'MIGRATION_REPORT.md'))
}

function Start-CodeRestore([string] $name) {
    $script = [System.IO.Path]::Combine($ToolsDir, $name, 'Restore-Backup.ps1')
    if (-not [System.IO.File]::Exists($script)) { throw "No Restore-Backup.ps1 in $name" }
    return Start-LocalJob "Restore code from $name" "& $(Quote $script)" $null
}

# =====================================================================================
# LISTINGS
# =====================================================================================

function Get-Listing {
    $reports = @()
    if ([System.IO.Directory]::Exists($OutputDir)) {
        $reports = @([System.IO.DirectoryInfo]::new($OutputDir).GetFiles('*.md') |
            Sort-Object LastWriteTime -Descending | Select-Object -First 200 |
            ForEach-Object { @{ name = $_.Name; time = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); size = $_.Length } })
    }
    $backups = @()
    if ([System.IO.Directory]::Exists($BackupsDir)) {
        $backups = @([System.IO.DirectoryInfo]::new($BackupsDir).GetDirectories() |
            Where-Object { [System.IO.File]::Exists([System.IO.Path]::Combine($_.FullName, 'manifest.json')) } |
            Sort-Object Name -Descending |
            ForEach-Object { @{ name = $_.Name; time = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } })
    }
    $audits = @()
    if ([System.IO.Directory]::Exists($ToolsDir)) {
        $audits = @([System.IO.DirectoryInfo]::new($ToolsDir).GetDirectories('qbx_migration_*') |
            Sort-Object Name -Descending |
            ForEach-Object {
                @{
                    name       = $_.Name
                    time       = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                    hasReport  = [System.IO.File]::Exists([System.IO.Path]::Combine($_.FullName, 'MIGRATION_REPORT.md'))
                    hasRestore = [System.IO.File]::Exists([System.IO.Path]::Combine($_.FullName, 'Restore-Backup.ps1'))
                }
            })
    }
    return @{ reports = $reports; backups = $backups; audits = $audits }
}

function Assert-SafeName([string] $name) {
    if (-not $name -or $name -notmatch '^[\w\-. ]+$' -or $name -match '\.\.') { throw "Bad name '$name'" }
}

# =====================================================================================
# FIVEM PROXY
# =====================================================================================

function Invoke-FiveM($s, [string] $method, [string] $path, [string] $body) {
    $url = $s.fivemUrl.TrimEnd('/') + '/qbx_migrate' + $path
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = $method
        $req.Timeout = 8000
        $req.Headers.Add('X-Qbxm-Token', (Get-Token $s))
        if ($body) {
            $bytes = $Utf8.GetBytes($body)
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Dispose()
        }
        $resp = $req.GetResponse()
    }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) {
            return @{ code = 502; body = (@{ error = "FiveM server not reachable at $($s.fivemUrl) - is it running with qbx_migrate started?"; offline = $true } | ConvertTo-Json) }
        }
    }
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), $Utf8)
        $text = $reader.ReadToEnd()
        $code = [int] $resp.StatusCode
        if ($code -eq 404 -and $text -notmatch '"error"') {
            $text = (@{ error = 'qbx_migrate is not started on the server (or is an old version without server/panel.lua).'; offline = $true } | ConvertTo-Json)
        }
        return @{ code = $code; body = $text }
    }
    finally { $resp.Dispose() }
}

# =====================================================================================
# HTTP
# =====================================================================================

function Send($ctx, [int] $code, [string] $body, [string] $type = 'application/json; charset=utf-8') {
    $bytes = $Utf8.GetBytes($body)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function SendJson($ctx, $obj, [int] $code = 200) { Send $ctx $code ($obj | ConvertTo-Json -Depth 8 -Compress) }

function Read-Body($ctx) {
    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, $Utf8)
    $text = $reader.ReadToEnd()
    if (-not $text) { return [pscustomobject]@{} }
    return $text | ConvertFrom-Json
}

function Handle($ctx, [int] $port) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    $q = $req.QueryString

    # Only this panel may drive the API: the Host check stops DNS rebinding, and the
    # custom header forces a CORS preflight no other site can pass.
    $hostOk = $req.Headers['Host'] -in @("localhost:$port", "127.0.0.1:$port")
    if (-not $hostOk) { return Send $ctx 403 'forbidden' 'text/plain' }

    if ($path -eq '/' -or $path -eq '/index.html') {
        return Send $ctx 200 ([System.IO.File]::ReadAllText($IndexFile)) 'text/html; charset=utf-8'
    }
    if (-not $path.StartsWith('/api/')) { return Send $ctx 404 'not found' 'text/plain' }
    if ($req.Headers['X-Qbxm-Panel'] -ne '1') { return Send $ctx 403 'forbidden' 'text/plain' }

    $s = Get-Settings
    switch ($path) {
        '/api/state' {
            $view = @{
                settings   = $s
                tokenFound = [bool] (Get-Token $s)
                tokenFile  = [System.IO.File]::Exists($TokenFile)
                root       = $Root
                toolFound  = [System.IO.File]::Exists($ToolScript)
            }
            foreach ($kv in (Get-Listing).GetEnumerator()) { $view[$kv.Key] = $kv.Value }
            return SendJson $ctx $view
        }
        '/api/settings' {
            $b = Read-Body $ctx
            foreach ($key in @($s.Keys)) { if ($null -ne $b.$key) { $s[$key] = ([string] $b.$key).Trim() } }
            if (-not $s.fivemUrl) { $s.fivemUrl = 'http://127.0.0.1:30120' }
            Save-Settings $s
            return SendJson $ctx @{ ok = $true }
        }
        '/api/server/status' {
            $r = Invoke-FiveM $s 'GET' '/status' $null
            return Send $ctx $r.code $r.body
        }
        '/api/server/job' {
            $r = Invoke-FiveM $s 'GET' ("/job?id={0}&from={1}" -f [int] $q['id'], [int] $q['from']) $null
            return Send $ctx $r.code $r.body
        }
        '/api/server/run' {
            $b = Read-Body $ctx
            $payload = @{ command = [string] $b.command; arg2 = [string] $b.arg2; arg3 = [string] $b.arg3 } | ConvertTo-Json -Compress
            $r = Invoke-FiveM $s 'POST' '/run' $payload
            return Send $ctx $r.code $r.body
        }
        '/api/audit' {
            $b = Read-Body $ctx
            $id = Start-Audit $s ([bool] $b.apply) ([bool] $b.aggressive)
            return SendJson $ctx @{ id = $id }
        }
        '/api/audit/restore' {
            $b = Read-Body $ctx
            Assert-SafeName $b.name
            $id = Start-CodeRestore $b.name
            return SendJson $ctx @{ id = $id }
        }
        '/api/local/job' {
            return SendJson $ctx (Get-LocalJobView ([int] $q['from']))
        }
        '/api/file' {
            $kind = $q['kind']; $name = $q['name']
            Assert-SafeName $name
            $file = switch ($kind) {
                'report' { [System.IO.Path]::Combine($OutputDir, $name) }
                'audit'  { [System.IO.Path]::Combine($ToolsDir, $name, 'MIGRATION_REPORT.md') }
                default  { throw "Bad kind '$kind'" }
            }
            if (-not [System.IO.File]::Exists($file)) { return SendJson $ctx @{ error = 'not found' } 404 }
            return Send $ctx 200 ([System.IO.File]::ReadAllText($file)) 'text/markdown; charset=utf-8'
        }
        '/api/open' {
            $b = Read-Body $ctx
            $target = switch ([string] $b.kind) {
                'output'  { $OutputDir }
                'backups' { $BackupsDir }
                'root'    { $Root }
                'audit'   { Assert-SafeName $b.name; [System.IO.Path]::Combine($ToolsDir, $b.name) }
                default   { throw "Bad kind '$($b.kind)'" }
            }
            if ([System.IO.Directory]::Exists($target)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $target + '"') }
            return SendJson $ctx @{ ok = $true }
        }
        default { return SendJson $ctx @{ error = 'not found' } 404 }
    }
}

# =====================================================================================
# MAIN
# =====================================================================================

$listener = $null
for ($p = $Port; $p -lt $Port + 20; $p++) {
    $candidate = New-Object System.Net.HttpListener
    $candidate.Prefixes.Add("http://localhost:$p/")
    try { $candidate.Start(); $listener = $candidate; break }
    catch { $candidate.Close() }
}
if (-not $listener) { throw "No free port between $Port and $($Port + 19)." }

$url = "http://localhost:$p/"
$Host.UI.RawUI.WindowTitle = "qbx_migrate panel - $url"
Write-Host ''
Write-Host '  qbx_migrate panel' -ForegroundColor Cyan
Write-Host "  running at $url" -ForegroundColor Green
Write-Host '  keep this window open while you use it; close it to stop the panel.' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $pending = $listener.GetContextAsync()
        # Short waits keep Ctrl+C responsive.
        while (-not $pending.AsyncWaitHandle.WaitOne(250)) { }
        $ctx = $pending.GetAwaiter().GetResult()
        try { Handle $ctx $p }
        catch {
            $msg = $_.Exception.Message
            Write-Host "  error on $($ctx.Request.Url.AbsolutePath): $msg" -ForegroundColor Red
            try { SendJson $ctx @{ error = $msg } 500 } catch { }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
