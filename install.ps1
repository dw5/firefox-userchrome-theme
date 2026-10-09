<#
.SYNOPSIS
  firefox-userchrome-theme - windows installer

.DESCRIPTION
  installs this theme into a firefox profile:
    chrome\        -> <profile>\chrome\           (userChrome.css)
    user.js        -> <profile>\user.js
    autoconfig.js  -> <firefox install dir>\defaults\pref\
    mozilla.cfg    -> <firefox install dir>\      (may prompt for admin via UAC)
    policies.json  -> <firefox install dir>\distribution\  (duckduckgo default + uBlock Origin)

  existing chrome\ and user.js are backed up as *.bak-<timestamp> first.

.EXAMPLE
  .\install.bat              (double-click)
  .\install.ps1
  .\install.ps1 -TargetProfile xxxx.default-release
  .\install.ps1 -Uninstall
  .\install.ps1 -Yes
#>
[CmdletBinding()]
param(
    [Alias('p')]
    [string]$TargetProfile = '',

    [Alias('u')]
    [switch]$Uninstall,

    [Alias('y')]
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$RepoDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Marker      = 'firefox-userchrome-theme'
$Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$Interactive = -not [Console]::IsInputRedirected

function Info($m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

$ProfileRoots = @(
    (Join-Path $env:APPDATA 'Mozilla\Firefox'),
    (Join-Path $env:APPDATA 'librewolf'),
    (Join-Path $env:APPDATA 'Waterfox')
)

# --- repo sanity -------------------------------------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir 'user.js')))       { Fail "user.js not found next to install.ps1" }
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir 'autoconfig.js'))) { Fail "autoconfig.js not found next to install.ps1" }
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir 'mozilla.cfg')))   { Fail "mozilla.cfg not found next to install.ps1" }
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir 'policies.json'))) { Fail "policies.json not found next to install.ps1" }
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir 'chrome')))        { Fail "chrome\ not found next to install.ps1" }

# --- profile discovery -------------------------------------------------------
function Get-IniSections([string]$path) {
    $sections = @{}
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            $current = $Matches[1]
            $sections[$current] = @{}
        }
        elseif ($current -and $line -match '^\s*([^=;#\r]+?)\s*=\s*(.*?)\s*$') {
            $sections[$current][$Matches[1]] = $Matches[2]
        }
    }
    return $sections
}

function Add-ProfileDir($list, [string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $resolved = (Resolve-Path -LiteralPath $dir).ProviderPath.TrimEnd('\')
    $dup = @($list | Where-Object { $_ -ieq $resolved })
    if ($dup.Count -eq 0) { $list.Add($resolved) | Out-Null }
}

function Get-Profiles {
    $found = New-Object System.Collections.Generic.List[string]

    foreach ($root in $ProfileRoots) {
        $ini = Join-Path $root 'profiles.ini'
        if (-not (Test-Path -LiteralPath $ini)) { continue }

        $sections = Get-IniSections $ini
        $rels = @()

        # [Install...] sections point at the profile firefox actually launches
        foreach ($key in $sections.Keys) {
            if ($key -like 'Install*' -and $sections[$key]['Default']) {
                $rels += $sections[$key]['Default']
            }
        }

        # classic [ProfileN] sections flagged Default=1
        if ($rels.Count -eq 0) {
            foreach ($key in $sections.Keys) {
                if ($key -like 'Profile*' -and $sections[$key]['Default'] -eq '1' -and $sections[$key]['Path']) {
                    $rels += $sections[$key]['Path']
                }
            }
        }

        foreach ($rel in $rels) {
            $full = $rel
            if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $root $rel }
            Add-ProfileDir $found $full
        }
    }

    # fallback: glob common profile dir names
    if ($found.Count -eq 0) {
        foreach ($root in $ProfileRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($sub in @('', 'Profiles')) {
                Get-ChildItem -Path (Join-Path $root $sub) -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*.default*' } |
                    ForEach-Object { Add-ProfileDir $found $_.FullName }
            }
        }
    }

    return ,$found.ToArray()
}

function Select-ProfileDir([string[]]$dirs) {
    if ($dirs.Count -eq 0) {
        Fail "no firefox profile found.`nsearched: $($ProfileRoots -join ', ')`nopen about:profiles in firefox to find your profile root dir."
    }

    if ($TargetProfile) {
        foreach ($d in $dirs) {
            if ($d -ieq $TargetProfile -or $d -like "*\$TargetProfile" -or $d -like "*/$TargetProfile") {
                return $d
            }
        }
        Fail "no profile matches '$TargetProfile'"
    }

    if ($dirs.Count -eq 1) { return $dirs[0] }

    if (-not $Interactive) { Fail "multiple profiles found; rerun with -TargetProfile <name>" }

    Write-Host 'multiple profiles found:'
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $dirs[$i])
    }
    while ($true) {
        $n = Read-Host 'install to which profile? [1]'
        if (-not $n) { $n = '1' }
        $num = 0
        if ([int]::TryParse($n, [ref]$num) -and $num -ge 1 -and $num -le $dirs.Count) {
            return $dirs[$num - 1]
        }
        Write-Host '  invalid choice'
    }
}

# --- helpers -----------------------------------------------------------------
function Backup-Item([string]$path) {
    if (Test-Path -LiteralPath $path) {
        $bak = "$path.bak-$Stamp"
        Move-Item -LiteralPath $path -Destination $bak -Force
        Info ("backed up {0} -> {1}" -f (Split-Path -Leaf $path), (Split-Path -Leaf $bak))
    }
}

function Test-IsOurs([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    if (Select-String -LiteralPath $path -Pattern $Marker -SimpleMatch -Quiet) { return $true }
    # policies.json is plain json (no comments allowed), so identify ours by content
    return [bool]((Select-String -LiteralPath $path -Pattern 'uBlock0@raymondhill.net' -SimpleMatch -Quiet) -and
                  (Select-String -LiteralPath $path -Pattern 'DuckDuckGo' -SimpleMatch -Quiet))
}

function Place-File([string]$src, [string]$dst) {
    if ((Test-Path -LiteralPath $dst) -and -not (Test-IsOurs $dst)) {
        Backup-Item $dst
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
}

function Test-FirefoxRunning {
    return [bool](Get-Process -Name firefox, firefox-esr, librewolf, waterfox -ErrorAction SilentlyContinue)
}

function Warn-IfFirefoxRunning {
    if (Test-FirefoxRunning) {
        Warn 'firefox is running - restart it after this to apply changes'
    }
}

# Apply saved toolbar customization once per install, never through user.js.
function Invoke-NavbarTidy([string]$profileDir) {
    if (Test-FirefoxRunning) {
        Warn 'navbar tidy skipped: firefox is running and would overwrite prefs.js; fully quit it and rerun the installer'
        return
    }
    $path = Join-Path $profileDir 'prefs.js'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $temporary = $null
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = [System.IO.File]::ReadAllText($path, $utf8)
        $pattern = '(?m)^(\s*user_pref\("browser\.uiCustomization\.state",\s*)("(?:[^"\\\r\n]|\\.)*")(\s*\);[^\r\n]*)'
        $found = [regex]::Matches($text, $pattern)
        if ($found.Count -eq 0) {
            if ($text -match '(?m)^\s*user_pref\("browser\.uiCustomization\.state"') {
                throw 'malformed customization pref'
            }
            return
        }
        if ($found.Count -ne 1) { throw 'multiple customization prefs' }
        $match = $found[0]
        $json = ConvertFrom-Json -InputObject $match.Groups[2].Value
        $state = ConvertFrom-Json -InputObject $json
        $navbar = $state.placements.'nav-bar'
        if ($navbar -isnot [System.Array]) { throw 'navbar placements must be an array of strings' }
        foreach ($item in $navbar) {
            if ($item -isnot [string]) { throw 'navbar placements must be an array of strings' }
        }
        if ($navbar -cnotcontains 'urlbar-container') { throw 'navbar has no urlbar-container' }
        # the search box goes directly after the urlbar, wherever it was before
        # (another nav-bar slot or another toolbar), so drop it everywhere first
        $before = @{}
        foreach ($area in @($state.placements.PSObject.Properties)) {
            if ($area.Value -isnot [System.Array]) { continue }
            $before[$area.Name] = $area.Value -join "`n"
            $state.placements.($area.Name) = @($area.Value | Where-Object { $_ -cne 'search-container' })
        }
        $tidy = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $state.placements.'nav-bar') {
            if ($item -cne 'toolbarspring' -and $item -cnotmatch '^customizableui-special-spring\d+$') {
                $tidy.Add($item)
            }
        }
        $tidy.Insert($tidy.IndexOf('urlbar-container') + 1, 'search-container')
        $state.placements.'nav-bar' = $tidy.ToArray()
        $changed = $false
        foreach ($name in $before.Keys) {
            if ((@($state.placements.$name) -join "`n") -cne $before[$name]) { $changed = $true; break }
        }
        if (-not $changed) { return }
        $json = ConvertTo-Json -InputObject $state -Depth 100 -Compress
        $quoted = ConvertTo-Json -InputObject $json -Compress
        $group = $match.Groups[2]
        $updated = $text.Substring(0, $group.Index) + $quoted + $text.Substring($group.Index + $group.Length)
        $backup = "$path.bak-$Stamp"
        [System.IO.File]::Copy($path, $backup, $false)
        $temporary = Join-Path $profileDir ('.prefs.js-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($temporary, $updated, $utf8)
        [System.IO.File]::Replace($temporary, $path, $null)
        $temporary = $null
        Info ("tidied navbar; backed up prefs.js -> {0}" -f (Split-Path -Leaf $backup))
    }
    catch {
        Warn ("navbar tidy skipped: {0}" -f $_.Exception.Message)
    }
    finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- autoconfig + policies ---------------------------------------------------
function Get-FirefoxInstallDir {
    $dirs = @()

    # the firefox installer registers its location in the registry
    foreach ($root in 'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox', 'HKCU:\SOFTWARE\Mozilla\Mozilla Firefox') {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $mainKey = $_.PSPath + '\Main'
            $props = Get-ItemProperty -Path $mainKey -ErrorAction SilentlyContinue
            if ($props) {
                if ($props.'Install Directory') { $dirs += $props.'Install Directory' }
                elseif ($props.PathToExe)       { $dirs += (Split-Path -Parent $props.PathToExe) }
            }
        }
    }

    $dirs += "$env:ProgramFiles\Mozilla Firefox"
    $dirs += "${env:ProgramFiles(x86)}\Mozilla Firefox"
    $dirs += "$env:LOCALAPPDATA\Mozilla Firefox"

    foreach ($d in $dirs) {
        if ($d -and (Test-Path -LiteralPath $d) -and (Test-Path -LiteralPath (Join-Path $d 'firefox.exe'))) {
            return $d
        }
    }
    return $null
}

function Test-CanWrite([string]$dir) {
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $dir '.write-test'
        Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Install-Autoconfig {
    $installDir = Get-FirefoxInstallDir
    if (-not $installDir) {
        Warn 'could not locate the firefox install dir - skipping mozilla.cfg/policies part'
        Warn '(chrome\ + user.js are installed; duckduckgo default + uBlock auto-install just won''t apply)'
        return
    }
    Info "firefox install dir: $installDir"

    $prefDir = Join-Path $installDir 'defaults\pref'
    $distDir = Join-Path $installDir 'distribution'

    if (Test-CanWrite $prefDir) {
        try {
            New-Item -ItemType Directory -Path $distDir -Force -ErrorAction Stop | Out-Null
            Place-File (Join-Path $RepoDir 'autoconfig.js') (Join-Path $prefDir 'autoconfig.js')
            Place-File (Join-Path $RepoDir 'mozilla.cfg')   (Join-Path $installDir 'mozilla.cfg')
            Place-File (Join-Path $RepoDir 'policies.json') (Join-Path $distDir 'policies.json')
            Info 'installed autoconfig.js + mozilla.cfg + policies.json (duckduckgo default, uBlock Origin)'
        }
        catch {
            Warn ("failed to write install dir files: {0}" -f $_.Exception.Message)
        }
        return
    }

    if ($Yes -or -not $Interactive) {
        Warn "no write access to $installDir - to finish the mozilla.cfg + policies part, run in an admin powershell:"
        Write-Host "  New-Item -ItemType Directory -Force '$prefDir', '$distDir'"
        Write-Host "  Copy-Item '$RepoDir\autoconfig.js' '$prefDir\' -Force"
        Write-Host "  Copy-Item '$RepoDir\mozilla.cfg' '$installDir\' -Force"
        Write-Host "  Copy-Item '$RepoDir\policies.json' '$distDir\' -Force"
        return
    }

    $a = Read-Host "write access to $installDir requires admin - elevate now? [Y/n]"
    if ($a -match '^(n|no)$') {
        Warn 'skipped autoconfig/policies install (rerun later to retry)'
        return
    }
    $inner = "New-Item -ItemType Directory -Force -Path '$prefDir', '$distDir' | Out-Null; " +
             "Copy-Item '$RepoDir\autoconfig.js' '$prefDir\' -Force; " +
             "Copy-Item '$RepoDir\mozilla.cfg' '$installDir\' -Force; " +
             "Copy-Item '$RepoDir\policies.json' '$distDir\' -Force"
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $inner
        Info 'installed autoconfig.js + mozilla.cfg + policies.json (elevated)'
    }
    catch {
        Warn "elevation cancelled or failed - mozilla.cfg/policies part skipped"
    }
}

function Uninstall-Autoconfig {
    $installDir = Get-FirefoxInstallDir
    if (-not $installDir) { return }
    foreach ($f in @(
        (Join-Path $installDir 'defaults\pref\autoconfig.js'),
        (Join-Path $installDir 'mozilla.cfg'),
        (Join-Path $installDir 'distribution\policies.json'))) {
        if (Test-Path -LiteralPath $f) {
            if (Test-IsOurs $f) {
                Remove-Item -LiteralPath $f -Force
                Info "removed $f"
            }
            else {
                Warn "$f was not installed by this script - leaving it alone"
            }
        }
    }
}

# --- install / uninstall -----------------------------------------------------
function Invoke-Install([string[]]$dirs) {
    $p = Select-ProfileDir $dirs
    Info "profile: $p"
    Warn-IfFirefoxRunning

    Backup-Item (Join-Path $p 'chrome')
    Backup-Item (Join-Path $p 'user.js')

    Copy-Item -Recurse -Force -LiteralPath (Join-Path $RepoDir 'chrome') -Destination (Join-Path $p 'chrome')
    Copy-Item -Force -LiteralPath (Join-Path $RepoDir 'user.js') -Destination (Join-Path $p 'user.js')
    Info 'installed chrome\ and user.js'

    Invoke-NavbarTidy $p
    Install-Autoconfig

    Write-Host ''
    Info 'done - restart firefox to apply the theme'
}

function Invoke-Uninstall([string[]]$dirs) {
    $p = Select-ProfileDir $dirs
    Info "profile: $p"
    Warn-IfFirefoxRunning

    $chromeBaks = @(Get-ChildItem -LiteralPath $p -Filter 'chrome.bak-*' -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    $jsBaks     = @(Get-ChildItem -LiteralPath $p -Filter 'user.js.bak-*' -File -ErrorAction SilentlyContinue | Sort-Object Name)

    Remove-Item -LiteralPath (Join-Path $p 'chrome') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $p 'user.js') -Force -ErrorAction SilentlyContinue
    Info 'removed chrome\ and user.js'

    $restore = $true
    if (($chromeBaks.Count -gt 0 -or $jsBaks.Count -gt 0) -and $Interactive -and -not $Yes) {
        $a = Read-Host 'restore latest backup? [Y/n]'
        if ($a -match '^(n|no)$') { $restore = $false }
    }
    if ($restore) {
        if ($chromeBaks.Count -gt 0) {
            Move-Item -LiteralPath $chromeBaks[-1].FullName -Destination (Join-Path $p 'chrome') -Force
            Info "restored $($chromeBaks[-1].Name)"
        }
        if ($jsBaks.Count -gt 0) {
            Move-Item -LiteralPath $jsBaks[-1].FullName -Destination (Join-Path $p 'user.js') -Force
            Info "restored $($jsBaks[-1].Name)"
        }
    }

    Uninstall-Autoconfig

    Write-Host ''
    Info 'done - restart firefox'
}

# --- main --------------------------------------------------------------------
$profiles = Get-Profiles
if ($Uninstall) { Invoke-Uninstall $profiles } else { Invoke-Install $profiles }
