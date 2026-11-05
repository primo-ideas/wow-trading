#Requires -Version 7.2
<#
.SYNOPSIS
Fetches the WoW auction data, starts the local site and opens it in the browser.

.DESCRIPTION
On first use, installs Postgres and Ruby in %LOCALAPPDATA%\wow-market, without
admin rights and without touching the PATH or creating a service. Then starts
Postgres, runs one fetch cycle, starts the site, opens the browser, and keeps
fetching until Ctrl-C. Everything this script started is stopped when it exits.

.PARAMETER Scope
What to fetch, to go faster than everything: a region (eu), a realm (eu/hyjal),
only the commodity market (eu/commodities), or a comma-separated mix
("eu/hyjal,eu/archimonde,us"). Default: every realm of every region.

.PARAMETER Config
File holding the Battle.net credentials, one KEY=VALUE per line, see .env.example.
Default: .env at the root of the repository.

.PARAMETER Stub
Uses a simulated week of sample data in a separate database. Needs no credentials.

.PARAMETER Port
Port of the local site.

.PARAMETER NoBrowser
Does not open the browser.

.PARAMETER SetupOnly
Installs what is missing and exits.

.PARAMETER Test
Runs the fetcher and site test suites and exits.

.EXAMPLE
./run.ps1 -Config C:\secrets\wow.env -Scope eu/hyjal

.EXAMPLE
./run.ps1 -Stub
#>
[CmdletBinding()]
param(
    [string] $Scope = '',
    [string] $Config = '',
    [switch] $Stub,
    [ValidateRange(1, 65535)]
    [int] $Port = 3000,
    [switch] $NoBrowser,
    [switch] $SetupOnly,
    [switch] $Test
)

$ErrorActionPreference = 'Stop'

$Repo = $PSScriptRoot
$Home_ = Join-Path $env:LOCALAPPDATA 'wow-market'
$Downloads = Join-Path $Home_ 'downloads'
$Logs = Join-Path $Home_ 'logs'
$PgRoot = Join-Path $Home_ 'postgres'
$PgBin = Join-Path $PgRoot 'pgsql\bin'
$PgData = Join-Path $Home_ 'pgdata'
$PgPasswordFile = Join-Path $Home_ 'pg-password.txt'
$RubyRoot = Join-Path $Home_ 'ruby'
$Web = Join-Path $Repo 'web'

$PgPort = 54329
$PgUser = 'wowmarket'
$Database = 'wow_market'

# The Ruby checksum comes from the winget manifest. EDB publishes none for this
# archive: this one was recorded on the first download.
$PgArchive = @{
    Url    = 'https://get.enterprisedb.com/postgresql/postgresql-17.11-5-windows-x64-binaries.zip'
    Sha256 = '80379b2c04d51c30225532e0ae04509899141e9957ed096fe749d7fd9df8f82f'
}
$RubyInstaller = @{
    Url    = 'https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-3.4.11-1/rubyinstaller-devkit-3.4.11-1-x64.exe'
    Sha256 = '65ff9e694aeea5c259162d20d73e062112a2a876c9a75a81913715573d79ad78'
}

# Below this, warn: Postgres stops working when its disk is full.
$MinFreeDiskGb = 20

function Write-Step([string] $Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Runs a native command and throws if it fails.
function Invoke-Checked([string] $Command, [string[]] $Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE"
    }
}

function Get-VerifiedDownload([hashtable] $Source, [string] $Name) {
    $directory = Join-Path $Downloads $Name
    New-Item -ItemType Directory -Force $directory | Out-Null
    $file = Join-Path $directory (Split-Path $Source.Url -Leaf)

    if (-not (Test-Path $file)) {
        Write-Step "Downloading $(Split-Path $file -Leaf)"
        Invoke-Checked 'curl.exe' @('-fSL', '--retry', '3', '--progress-bar', '-o', "$file.part", $Source.Url)
        Move-Item -Force "$file.part" $file
    }
    $actual = (Get-FileHash -Algorithm SHA256 $file).Hash
    if ($actual -ne $Source.Sha256) {
        Remove-Item $file
        throw "Checksum mismatch for $file (got $actual): deleted it, nothing was installed."
    }
    $file
}

function Install-Postgres {
    if (Test-Path (Join-Path $PgBin 'pg_ctl.exe')) { return }

    $archive = Get-VerifiedDownload $PgArchive 'postgres'
    Write-Step 'Unpacking Postgres'
    New-Item -ItemType Directory -Force $PgRoot | Out-Null
    # The archive also holds tools that are not needed here, and most of its size.
    Invoke-Checked (Join-Path $env:SystemRoot 'System32\tar.exe') @(
        '-xf', $archive, '-C', $PgRoot,
        '--exclude', 'pgsql/pgAdmin 4/*',
        '--exclude', 'pgsql/StackBuilder/*',
        '--exclude', 'pgsql/doc/*',
        '--exclude', 'pgsql/symbols/*'
    )
}

function Initialize-PostgresData {
    if (Test-Path (Join-Path $PgData 'PG_VERSION')) { return }

    Write-Step 'Creating the Postgres data directory'
    $password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLower()
    Set-Content -NoNewline -Path $PgPasswordFile -Value $password
    try {
        Invoke-Checked (Join-Path $PgBin 'initdb.exe') @(
            '-D', $PgData, '-U', $PgUser, '--encoding=UTF8', '--locale=C',
            '--auth=scram-sha-256', "--pwfile=$PgPasswordFile"
        )
    }
    catch {
        Remove-Item -Recurse -Force $PgData -ErrorAction SilentlyContinue
        throw
    }
    # Only this machine can connect. Losing the last commits in a crash is fine:
    # the next fetch cycle gets those snapshots again.
    Add-Content -Path (Join-Path $PgData 'postgresql.conf') -Value @"

listen_addresses = '127.0.0.1'
port = $PgPort
shared_buffers = 512MB
max_wal_size = 4GB
synchronous_commit = off
"@
}

function Install-Ruby {
    if (Test-Path (Join-Path $RubyRoot 'bin\ruby.exe')) { return }

    $installer = Get-VerifiedDownload $RubyInstaller 'ruby'
    Write-Step 'Installing Ruby (several minutes)'
    # These /TASKS are specific to this installer: without them, it adds Ruby to
    # the PATH and PATHEXT of the account and takes over .rb and .rbw files.
    $process = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
        "/DIR=`"$RubyRoot`"", '/TASKS=NOMODPATH,NOASSOCFILES,NORIDKINSTALL'
    )
    if ($process.ExitCode -ne 0) {
        throw "The Ruby installer failed with exit code $($process.ExitCode)."
    }
}

function Test-PostgresRunning {
    & (Join-Path $PgBin 'pg_ctl.exe') -D $PgData status *> $null
    $LASTEXITCODE -eq 0
}

# Returns whether this call started it: a server already running belongs to
# someone else and must survive this script.
function Start-Postgres {
    if (Test-PostgresRunning) { return $false }

    Write-Step 'Starting Postgres'
    New-Item -ItemType Directory -Force $Logs | Out-Null
    $process = Start-Process -FilePath (Join-Path $PgBin 'pg_ctl.exe') -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $Logs 'pg_ctl.out') `
        -ArgumentList @('-D', "`"$PgData`"", '-l', "`"$(Join-Path $Logs 'postgres.log')`"", '-w', 'start')
    if ($process.ExitCode -ne 0) {
        throw "Postgres did not start, see $(Join-Path $Logs 'postgres.log')"
    }
    $true
}

function Stop-Postgres {
    Write-Step 'Stopping Postgres'
    if (Test-PostgresRunning) {
        & (Join-Path $PgBin 'pg_ctl.exe') -D $PgData -m fast -w stop *> $null
    }
}

function Get-DatabaseUrl([string] $Name) {
    $password = Get-Content -Raw $PgPasswordFile
    "postgres://${PgUser}:$password@127.0.0.1:$PgPort/$Name"
}

function New-DatabaseIfMissing([string] $Name) {
    $env:PGPASSWORD = Get-Content -Raw $PgPasswordFile
    try {
        $exists = & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $PgPort -U $PgUser -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$Name'"
        if ($exists -ne '1') {
            Invoke-Checked (Join-Path $PgBin 'createdb.exe') @('-h', '127.0.0.1', '-p', "$PgPort", '-U', $PgUser, $Name)
        }
    }
    finally {
        Remove-Item Env:PGPASSWORD
    }
}

function Install-WebDependencies {
    Push-Location $Web
    try {
        & bundle check *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Step 'Installing the site dependencies (several minutes the first time)'
            Invoke-Checked 'bundle' @('install', '--quiet')
        }
    }
    finally {
        Pop-Location
    }
}

function Test-PortInUse([int] $Number) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.ConnectAsync('127.0.0.1', $Number).Wait(500) -and $client.Connected
    }
    catch {
        $false
    }
    finally {
        $client.Dispose()
    }
}

function Start-Site {
    if (Test-PortInUse $Port) {
        throw "Port $Port is already in use. Pick another one with -Port."
    }
    # Left behind if a previous run was killed; Rails refuses to start otherwise.
    Remove-Item (Join-Path $Web 'tmp\pids\server.pid') -ErrorAction SilentlyContinue

    Write-Step "Starting the site on port $Port"
    $ruby = (Get-Command ruby.exe).Source
    Start-Process -FilePath $ruby -PassThru -NoNewWindow -WorkingDirectory $Web `
        -RedirectStandardOutput (Join-Path $Logs 'site.log') `
        -RedirectStandardError (Join-Path $Logs 'site-error.log') `
        -ArgumentList @('bin/rails', 'server', '-b', '127.0.0.1', '-p', "$Port")
}

function Wait-Site([Diagnostics.Process] $Process) {
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            Get-Content (Join-Path $Logs 'site-error.log') -Tail 20 | Write-Host
            throw "The site stopped while starting, see $Logs"
        }
        try {
            Invoke-WebRequest "http://127.0.0.1:$Port/up" -TimeoutSec 5 -SkipHttpErrorCheck | Out-Null
            return
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "The site did not answer within 3 minutes, see $Logs"
}

function Stop-IfRunning([Diagnostics.Process] $Process) {
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Tests {
    Write-Step 'Testing the fetcher'
    New-DatabaseIfMissing 'wow_market_fetcher_test'
    $env:DATABASE_URL = Get-DatabaseUrl 'wow_market_fetcher_test'
    Push-Location $Repo
    try {
        Invoke-Checked 'cargo' @('test', '--workspace')
    }
    finally {
        Pop-Location
    }

    Write-Step 'Testing the site'
    Install-WebDependencies
    New-DatabaseIfMissing 'wow_market_site_test'
    $env:DATABASE_URL = Get-DatabaseUrl 'wow_market_site_test'
    Push-Location $Web
    try {
        Invoke-Checked 'ruby' @('bin/rails', 'test')
    }
    finally {
        Pop-Location
    }
}

# Where credentials come from, as arguments for the fetcher. Fails right away
# rather than after minutes of installation.
function Get-ConfigArguments {
    if ($Stub -or $SetupOnly -or $Test) { return @() }
    if ($Config) {
        if (-not (Test-Path -PathType Leaf $Config)) {
            throw "Config file not found: $Config"
        }
        # The file is the explicit choice: ambient values must not win over it.
        Remove-Item Env:BLIZZARD_CLIENT_ID, Env:BLIZZARD_CLIENT_SECRET -ErrorAction SilentlyContinue
        return @('--config', (Resolve-Path $Config).Path)
    }
    if (Test-Path -PathType Leaf (Join-Path $Repo '.env')) { return @() }
    throw 'Battle.net credentials are needed: pass -Config <file> (see .env.example), or -Stub to use sample data.'
}

function Write-DiskWarning {
    $drive = [IO.DriveInfo]::new($Home_)
    $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB)
    if ($freeGb -lt $MinFreeDiskGb) {
        Write-Warning "Only $freeGb GB left on $($drive.Name), where the database lives. Postgres stops working when the disk is full."
    }
}

$site = $null
$watcher = $null
$startedPostgres = $false

try {
    $configArguments = @(Get-ConfigArguments)
    $scopeArguments = if ($Scope) { @('--scope', $Scope) } else { @() }
    $stubArguments = if ($Stub) { @('--stub') } else { @() }

    New-Item -ItemType Directory -Force $Home_, $Logs | Out-Null
    Install-Postgres
    Initialize-PostgresData
    Install-Ruby
    $env:PATH = "$(Join-Path $RubyRoot 'bin');$PgBin;$env:PATH"
    if ($SetupOnly) {
        Write-Step "Installed in $Home_"
        return
    }

    Write-DiskWarning
    $startedPostgres = Start-Postgres

    if ($Test) {
        Invoke-Tests
        return
    }

    # Both the fetcher and the site read the database from here. With --stub, the
    # fetcher adds this same suffix itself so sample data can never reach the real database.
    $env:DATABASE_URL = Get-DatabaseUrl $Database
    $siteDatabaseUrl = Get-DatabaseUrl ($Stub ? "${Database}_stub" : $Database)

    Write-Step 'Building the fetcher'
    Push-Location $Repo
    try {
        Invoke-Checked 'cargo' @('build', '--release', '--quiet', '-p', 'wow-market-fetcher')
    }
    finally {
        Pop-Location
    }
    $fetcher = Join-Path $Repo 'target\release\wow-market-fetcher.exe'
    $fetcherArguments = $configArguments + $scopeArguments + $stubArguments

    Install-WebDependencies

    Write-Step "Fetching $($Stub ? 'simulated data' : ($Scope ? $Scope : 'every realm of every region'))"
    & $fetcher @fetcherArguments once
    switch ($LASTEXITCODE) {
        0 {}
        2 { Write-Warning 'Some markets failed and will be retried: showing what was fetched.' }
        default { throw "The fetch failed with exit code $LASTEXITCODE, see above." }
    }

    $env:DATABASE_URL = $siteDatabaseUrl
    $site = Start-Site
    Wait-Site $site
    $env:DATABASE_URL = Get-DatabaseUrl $Database

    $url = "http://127.0.0.1:$Port/"
    if (-not $NoBrowser) {
        Start-Process $url
    }

    $watcher = Start-Process -FilePath $fetcher -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $Logs 'fetcher.log') `
        -RedirectStandardError (Join-Path $Logs 'fetcher-error.log') `
        -ArgumentList ($fetcherArguments + 'watch')

    Write-Step "Site: $url"
    Write-Step "Still fetching in the background, logs in $Logs. Ctrl-C to stop everything."
    $watcherReported = $false
    while (-not $site.HasExited) {
        if ($watcher.HasExited -and -not $watcherReported) {
            Write-Warning "Fetching stopped, see $Logs. The site stays up."
            $watcherReported = $true
        }
        Start-Sleep -Seconds 1
    }
    throw "The site stopped, see $Logs"
}
finally {
    Stop-IfRunning $watcher
    Stop-IfRunning $site
    if ($startedPostgres) {
        Stop-Postgres
    }
}
