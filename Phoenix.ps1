#Requires -Version 5.1
<#
    Phoenix - Windows Migration Kit
    A self-contained backup & restore tool for migrating to a fresh Windows install.
    Run via Phoenix.cmd (launches Windows PowerShell in STA mode for WPF).

    Headless (for scheduled tasks):
      Phoenix.cmd -Headless -Dest D:\Backups [-Preset Developer | -Items id1,id2] [-Update] [-Encrypt] [-NoChecksums]
      -Update  reuses the newest Phoenix-Backup-<PC>-* folder in -Dest (mirror update) instead of creating a new one.
      -Encrypt reads the vault password from the PHOENIX_VAULT_PASSWORD environment variable.
#>
[CmdletBinding()] param(
    [switch]$Headless,
    [string]$Dest,
    [string]$Preset = 'Developer',
    [string[]]$Items,
    [switch]$Update,
    [switch]$Encrypt,
    [switch]$NoChecksums
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing | Out-Null

#region ------------------------------------------------------------ Module catalog (UI metadata)
# Categories render in this order.
$Script:Categories = @('Applications','Developer Environment','Windows Settings','App Settings & Data','User Folders')

# Each module: Id, Cat, Name, Desc, Sensitive, Admin, Presets (Minimal/Developer). "Everything" = all.
$Script:Modules = @(
    @{ Id='apps_winget';   Cat='Applications'; Name='Installed apps (winget)';        Desc='Exports every winget/Store package so they reinstall unattended.'; Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='apps_ubundle';  Cat='Applications'; Name='UniGetUI bundle';                 Desc='Copies an apps.ubundle from your Desktop if present.';             Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='apps_inventory';Cat='Applications'; Name='Installed programs inventory';   Desc='Every program in Add/Remove Programs (incl. non-winget) as a CSV checklist.'; Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }

    @{ Id='dev_vscode';    Cat='Developer Environment'; Name='Editor extensions';       Desc='VS Code, Insiders & Cursor extension lists.';                      Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='dev_node';      Cat='Developer Environment'; Name='Node globals';            Desc='Global npm packages + nvm/fnm installed versions.';                Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_python';    Cat='Developer Environment'; Name='Python packages';         Desc='pip freeze per installed Python version.';                         Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_rust';      Cat='Developer Environment'; Name='Rust toolchains';         Desc='rustup toolchains + globally installed cargo crates.';             Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_dotnet';    Cat='Developer Environment'; Name='.NET global tools';       Desc='dotnet tool list (global).';                                       Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_git';       Cat='Developer Environment'; Name='Git configuration';       Desc='.gitconfig and global ignore. Credentials go to the vault.';       Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='dev_ssh';       Cat='Developer Environment'; Name='SSH keys';                Desc='Your ~/.ssh folder (private keys).';                               Sensitive=$true;  Admin=$false; Presets=@('Developer') }
    @{ Id='dev_ps';        Cat='Developer Environment'; Name='PowerShell profile';      Desc='$PROFILE + installed module names.';                               Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_wsl';       Cat='Developer Environment'; Name='WSL distros (list)';      Desc='Records installed WSL distributions (informational).';             Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_wsl_export';Cat='Developer Environment'; Name='WSL distros (full export)'; Desc='wsl --export of every distro to .tar (can be many GB). Re-imported on restore.'; Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='dev_env';       Cat='Developer Environment'; Name='Environment variables';   Desc='User-scope variables incl. PATH.';                                 Sensitive=$false; Admin=$false; Presets=@('Developer') }

    @{ Id='win_wifi';      Cat='Windows Settings'; Name='Wi-Fi profiles';               Desc='Saved networks with passwords.';                                   Sensitive=$true;  Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='win_power';     Cat='Windows Settings'; Name='Power plans';                  Desc='Exports custom power schemes.';                                    Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_netadapter';Cat='Windows Settings'; Name='Network adapter settings';     Desc='Driver properties per NIC: Speed & Duplex, Jumbo Packet, Wake-on-LAN, RSS, offloads... Matched by MAC on restore (needs admin).'; Sensitive=$false; Admin=$true; Presets=@('Developer') }
    @{ Id='win_netip';     Cat='Windows Settings'; Name='Static IP & DNS';               Desc='Manual IPv4/IPv6 addresses, gateways, DNS servers and suffix per adapter. DHCP adapters are recorded but left alone. Matched by MAC on restore (needs admin).'; Sensitive=$false; Admin=$true; Presets=@('Developer') }
    @{ Id='win_drives';    Cat='Windows Settings'; Name='Mapped network drives';        Desc='SMB drive mappings.';                                              Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_hosts';     Cat='Windows Settings'; Name='Hosts file';                   Desc='C:\Windows\System32\drivers\etc\hosts.';                           Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_tasks';     Cat='Windows Settings'; Name='Scheduled tasks';              Desc='Your non-system scheduled tasks.';                                 Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='win_explorer';  Cat='Windows Settings'; Name='Explorer & taskbar tweaks';    Desc='Explorer Advanced registry (show extensions, hidden files, etc.).'; Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_terminal';  Cat='Windows Settings'; Name='Windows Terminal';             Desc='settings.json (themes, profiles, keybindings).';                   Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='win_printers';  Cat='Windows Settings'; Name='Printers (list)';              Desc='Records installed printers (informational).';                      Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='win_defaultapps';Cat='Windows Settings'; Name='Default app associations';    Desc='File-type defaults (requires admin to export).';                   Sensitive=$false; Admin=$true;  Presets=@() }
    @{ Id='win_fonts';     Cat='Windows Settings'; Name='User-installed fonts';         Desc='Fonts you added under your profile.';                              Sensitive=$false; Admin=$false; Presets=@() }

    @{ Id='app_appdata';   Cat='App Settings & Data'; Name='App configs (Smart)';       Desc='Curated settings for OBS, Notepad++, PowerToys, editors, etc. Caches skipped. Pick apps below.'; Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='app_bookmarks'; Cat='App Settings & Data'; Name='Browser bookmarks';         Desc='Chrome, Edge, Brave, Vivaldi bookmarks + Firefox places.sqlite, per profile.'; Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='app_browserprofiles'; Cat='App Settings & Data'; Name='Browser profiles (full)'; Desc='Whole browser profiles: extensions, sessions, cookies, saved logins. Caches skipped.'; Sensitive=$true; Admin=$false; Presets=@() }
    @{ Id='app_putty';     Cat='App Settings & Data'; Name='PuTTY sessions';            Desc='Saved sessions & host keys (registry).';                           Sensitive=$true;  Admin=$false; Presets=@('Developer') }

    @{ Id='user_documents';Cat='User Folders'; Name='Documents'; Desc='Mirror of your Documents folder.'; Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_desktop';  Cat='User Folders'; Name='Desktop';   Desc='Mirror of your Desktop folder.';   Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_pictures'; Cat='User Folders'; Name='Pictures';  Desc='Mirror of your Pictures folder.';  Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_downloads';Cat='User Folders'; Name='Downloads'; Desc='Mirror of your Downloads folder.'; Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_videos';   Cat='User Folders'; Name='Videos';    Desc='Mirror of your Videos folder.';    Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_music';    Cat='User Folders'; Name='Music';     Desc='Mirror of your Music folder.';     Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_custom';   Cat='User Folders'; Name='Custom folders'; Desc='Any other folders you add below (game saves, notes vault, projects...). Restored to their original paths.'; Sensitive=$false; Admin=$false; Presets=@() }
)
$Script:ModuleById = @{}
foreach ($m in $Script:Modules) { $Script:ModuleById[$m.Id] = $m }

# Curated AppData map. Shared with the worker via $sync so backup, restore and the picker agree.
$Script:AppDataMap = @(
    @{ Name='VSCode';          Src="$env:APPDATA\Code\User" }
    @{ Name='VSCode-Insiders'; Src="$env:APPDATA\Code - Insiders\User" }
    @{ Name='Cursor';          Src="$env:APPDATA\Cursor\User" }
    @{ Name='OBS';             Src="$env:APPDATA\obs-studio" }
    @{ Name='Notepad++';       Src="$env:APPDATA\Notepad++" }
    @{ Name='PowerToys';       Src="$env:LOCALAPPDATA\Microsoft\PowerToys" }
    @{ Name='WindowsTerminal'; Src="$env:LOCALAPPDATA\Microsoft\Windows Terminal" }
    @{ Name='AutoHotkey';      Src="$env:APPDATA\AutoHotkey" }
    @{ Name='FileZilla';       Src="$env:APPDATA\FileZilla" }
    @{ Name='7-Zip';           Src="$env:APPDATA\7-Zip" }
    @{ Name='Greenshot';       Src="$env:APPDATA\Greenshot" }
    @{ Name='mpv';             Src="$env:APPDATA\mpv" }
    @{ Name='Discord';         Src="$env:APPDATA\discord" }
)

# Persistent settings (custom folders, last destination).
$Script:SettingsPath = Join-Path $env:APPDATA 'Phoenix\settings.json'
$Script:Settings = @{ CustomFolders=@(); LastDest=$null }
try{
    if(Test-Path -LiteralPath $Script:SettingsPath){
        $j = Get-Content -LiteralPath $Script:SettingsPath -Raw | ConvertFrom-Json
        if($j.CustomFolders){ $Script:Settings.CustomFolders = @($j.CustomFolders | Where-Object { $_ }) }
        if($j.LastDest){ $Script:Settings.LastDest = [string]$j.LastDest }
    }
}catch{}
function Save-Settings {
    try{ $d=Split-Path $Script:SettingsPath -Parent; if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }; ($Script:Settings | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $Script:SettingsPath -Encoding UTF8 }catch{}
}
#endregion

#region ------------------------------------------------------------ Worker (runs in background runspace)
$Script:WorkerText = @'
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression.FileSystem, System.Drawing | Out-Null

function Fmt-Bytes($b){ if($null -eq $b){return '0 B'}; if($b -ge 1GB){'{0:N2} GB' -f ($b/1GB)} elseif($b -ge 1MB){'{0:N1} MB' -f ($b/1MB)} elseif($b -ge 1KB){'{0:N0} KB' -f ($b/1KB)} else {"$b B"} }
function Emit($t,$d){
    $sync.Events.Enqueue(@{ Type=$t; Data=$d })
    if($sync.Console){ if($t -eq 'Log'){ Write-Host $d.Msg } elseif($t -eq 'Progress'){ Write-Host ("[{0,3}%] {1}" -f $d.Pct,$d.Status) } }
}
function WL($m,$l){
    if(-not $l){$l='Info'}; Emit 'Log' @{ Msg=$m; Level=$l }
    if($sync.LogPath){ try{ Add-Content -LiteralPath $sync.LogPath -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$l,$m) -Encoding UTF8 }catch{} }
}
function Prog($p,$s){ Emit 'Progress' @{ Pct=$p; Status=$s } }
function EnsureDir($p){ if($p -and -not (Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function FolderSize($p){ if(-not (Test-Path -LiteralPath $p)){ return 0 }; try{ $s=(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if($null -eq $s){0}else{$s} }catch{ 0 } }
function CmdExists($n){ $null -ne (Get-Command $n -ErrorAction SilentlyContinue) }
function RelOf($root,$full){ $full.Substring($root.Length).TrimStart('\','/') }
$Script:HashFails=0; $Script:HashLastError=''
# Direct .NET SHA-256: no cmdlet resolution, long-path safe, ~10x faster than Get-FileHash on many small files.
function FileHash($p){
    try{
        $lp = if($p.Length -ge 248 -and -not $p.StartsWith('\\?\')){ '\\?\' + $p } else { $p }
        $fs=[System.IO.File]::Open($lp,'Open','Read','ReadWrite'); try{ $sha=[System.Security.Cryptography.SHA256]::Create(); try{ ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-','') } finally { $sha.Dispose() } } finally { $fs.Dispose() }
    }catch{ $Script:HashFails++; $Script:HashLastError=$_.Exception.Message; $null }
}
function SameFile($a,$b){ if(-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)){ return $false }; (FileHash $a) -eq (FileHash $b) }

# Per-module outcome tracking for the end-of-run report.
$Script:CurNote=''; $Script:CurStatus='ok'
function Note($t){ $Script:CurNote=$t }
function Manual($t){ $Script:CurNote=$t; $Script:CurStatus='manual' }
function Skip($t){ $Script:CurNote=$t; $Script:CurStatus='skip' }

$Script:SmartExcludes = @('Cache','Code Cache','GPUCache','ShaderCache','Service Worker','CacheStorage','GrShaderCache','Crashpad','Crashpad_reports','logs','Log','tmp','Temp','blob_storage','DawnCache','workspaceStorage','globalStorage','History','CachedData','CachedExtensions','CachedExtensionVSIXs','Backups','Local Storage','Session Storage','IndexedDB','DawnGraphiteCache','WebStorage','Media Cache','component_crx_cache','extensions_crx_cache','optimization_guide_model_store','OptGuideOnDeviceModel','OptGuideOnDeviceClassifierModel','SODALanguagePacks','File System','OnDeviceHeadSuggestModel','WidevineCdm','MEIPreload','hyphen-data','Safe Browsing','GrShaderCache','cache2','startupCache','thumbnails','minidumps','crashes','shader-cache')

function Robo($src,$dst,$smart){
    EnsureDir $dst
    $mode = if($sync.Mirror){ '/MIR' } else { '/E' }
    $a = @($src, $dst, $mode,'/R:1','/W:1','/NFL','/NDL','/NJH','/NJS','/NP','/XJ')
    if($smart){ foreach($x in $Script:SmartExcludes){ $a += '/XD'; $a += $x } }
    & robocopy @a *>$null
    $rc=$LASTEXITCODE
    # /MIR never purges /XD folders, so a Smart update of an older Full copy would keep its caches forever.
    if($smart -and $sync.Mirror){ $ex=@{}; foreach($x in $Script:SmartExcludes){ $ex[$x.ToLower()]=$true }; try{ Get-ChildItem -LiteralPath $dst -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $ex[$_.Name.ToLower()] } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } }catch{} }
    return $rc
}
# Dry-run copy plan: how many files robocopy would copy vs. skip.
function RoboPlan($src,$dst,$smart){
    if(-not (Test-Path -LiteralPath $src)){ return @{ Total=0; Copy=0; Skip=0; Bytes=0 } }
    $a = @($src, $dst, '/E','/L','/R:0','/W:0','/NFL','/NDL','/NJH','/NP','/XJ','/BYTES')
    if($smart){ foreach($x in $Script:SmartExcludes){ $a += '/XD'; $a += $x } }
    $out = & robocopy @a 2>$null
    $r=@{ Total=0; Copy=0; Skip=0; Bytes=0 }
    foreach($line in $out){
        if($line -match '^\s*Files\s*:\s*(\d+)\s+(\d+)\s+(\d+)'){ $r.Total=[long]$Matches[1]; $r.Copy=[long]$Matches[2]; $r.Skip=[long]$Matches[3] }
        elseif($line -match '^\s*Bytes\s*:\s*(\d+)\s+(\d+)'){ $r.Bytes=[long]$Matches[2] }
    }
    return $r
}
# Folder size honouring the Smart excludes (so estimates match what Robo actually copies).
function SmartSize($p){
    if(-not (Test-Path -LiteralPath $p)){ return 0 }
    $ex=@{}; foreach($x in $Script:SmartExcludes){ $ex[$x.ToLower()]=$true }
    $total=[long]0; $stack=New-Object System.Collections.Stack; $stack.Push($p)
    while($stack.Count -gt 0){
        $d=$stack.Pop()
        try{
            foreach($f in [System.IO.Directory]::EnumerateFiles($d)){ try{ $total += (New-Object System.IO.FileInfo($f)).Length }catch{} }
            foreach($s in [System.IO.Directory]::EnumerateDirectories($d)){ $leaf=[System.IO.Path]::GetFileName($s).ToLower(); if(-not $ex[$leaf]){ $stack.Push($s) } }
        }catch{}
    }
    return $total
}
# Known folder lookup so redirected Downloads etc. are honoured.
function KnownFolder($guid,$fallback){
    try{ $v=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).$guid; if($v){ $e=[Environment]::ExpandEnvironmentVariables($v); if(Test-Path -LiteralPath $e){ return $e } } }catch{}
    return $fallback
}
function DownloadsPath { KnownFolder '{374DE290-123F-4565-9164-39C4925E467B}' (Join-Path $env:USERPROFILE 'Downloads') }
function UserFolderPath($id){
    switch($id){
        'user_documents' { [Environment]::GetFolderPath('MyDocuments') }
        'user_desktop'   { [Environment]::GetFolderPath('Desktop') }
        'user_pictures'  { [Environment]::GetFolderPath('MyPictures') }
        'user_downloads' { DownloadsPath }
        'user_videos'    { [Environment]::GetFolderPath('MyVideos') }
        'user_music'     { [Environment]::GetFolderPath('MyMusic') }
    }
}
$Script:UserLeaf=@{ user_documents='Documents'; user_desktop='Desktop'; user_pictures='Pictures'; user_downloads='Downloads'; user_videos='Videos'; user_music='Music' }

# ---- Vault: AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC), PBKDF2-SHA256 200k. ----
# v2 layout: 'PHX2' | salt(16) | iv(16) | ciphertext | hmac(32).  v1 (no magic, SHA-1 KDF, no MAC) still decrypts.
$Script:VaultMagic = [byte[]](0x50,0x48,0x58,0x32)
function VaultKeys($pw,$salt,$v2){
    if($v2){ $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw,$salt,200000,[System.Security.Cryptography.HashAlgorithmName]::SHA256); $k=$kdf.GetBytes(64); return @{ Aes=$k[0..31]; Mac=$k[32..63] } }
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw,$salt,200000); return @{ Aes=$kdf.GetBytes(32); Mac=$null }
}
function Protect-File($inPath,$outPath,$pw){
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.GetBytes($iv)
    $keys = VaultKeys $pw $salt $true
    $aes = [System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Key=[byte[]]$keys.Aes; $aes.IV=$iv
    $out = [System.IO.File]::Open($outPath,'Create'); $out.Write($Script:VaultMagic,0,4); $out.Write($salt,0,16); $out.Write($iv,0,16)
    $cs  = New-Object System.Security.Cryptography.CryptoStream($out,$aes.CreateEncryptor(),'Write')
    $in  = [System.IO.File]::OpenRead($inPath); $in.CopyTo($cs); $in.Close(); $cs.FlushFinalBlock(); $cs.Close()
    # MAC over header + ciphertext, appended.
    $mac = [System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys.Mac)
    $fs = [System.IO.File]::Open($outPath,'Open','ReadWrite'); $tag=$mac.ComputeHash($fs); $fs.Seek(0,'End') | Out-Null; $fs.Write($tag,0,32); $fs.Close()
}
function Test-VaultMac($inPath,$pw){
    $fs=[System.IO.File]::OpenRead($inPath)
    try{
        if($fs.Length -lt 68){ return $false }
        $magic=New-Object byte[] 4; $null=$fs.Read($magic,0,4)
        if(-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$magic,[byte[]]$Script:VaultMagic)){ return $null }   # v1: no MAC to check
        $salt=New-Object byte[] 16; $null=$fs.Read($salt,0,16)
        $keys=VaultKeys $pw $salt $true
        $bodyLen=$fs.Length-32
        $fs.Seek($bodyLen,'Begin') | Out-Null; $stored=New-Object byte[] 32; $null=$fs.Read($stored,0,32)
        $fs.Seek(0,'Begin') | Out-Null
        $mac=[System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys.Mac)
        $buf=New-Object byte[] 1048576; $left=$bodyLen
        while($left -gt 0){ $n=$fs.Read($buf,0,[int][math]::Min($buf.Length,$left)); if($n -le 0){break}; $mac.TransformBlock($buf,0,$n,$null,0) | Out-Null; $left-=$n }
        $mac.TransformFinalBlock((New-Object byte[] 0),0,0) | Out-Null
        $calc=$mac.Hash; $diff=0; for($i=0;$i -lt 32;$i++){ $diff = $diff -bor ($calc[$i] -bxor $stored[$i]) }
        return ($diff -eq 0)
    } finally { $fs.Close() }
}
function Unprotect-File($inPath,$outPath,$pw){
    $in = [System.IO.File]::OpenRead($inPath)
    $magic=New-Object byte[] 4; $null=$in.Read($magic,0,4)
    $v2 = [System.Linq.Enumerable]::SequenceEqual([byte[]]$magic,[byte[]]$Script:VaultMagic)
    if(-not $v2){ $in.Seek(0,'Begin') | Out-Null }
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16; $null=$in.Read($salt,0,16); $null=$in.Read($iv,0,16)
    if($v2){ $in.Close(); if(-not (Test-VaultMac $inPath $pw)){ throw 'Vault integrity check failed (wrong password or corrupted file).' }; $in=[System.IO.File]::OpenRead($inPath); $in.Seek(36,'Begin') | Out-Null }
    $keys = VaultKeys $pw $salt $v2
    $aes = [System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Key=[byte[]]$keys.Aes; $aes.IV=$iv
    $out = [System.IO.File]::Open($outPath,'Create')
    $cs  = New-Object System.Security.Cryptography.CryptoStream($out,$aes.CreateDecryptor(),'Write')
    $left = if($v2){ $in.Length - 36 - 32 } else { $in.Length - 32 }
    $buf=New-Object byte[] 1048576
    while($left -gt 0){ $n=$in.Read($buf,0,[int][math]::Min($buf.Length,$left)); if($n -le 0){break}; $cs.Write($buf,0,$n); $left-=$n }
    $cs.FlushFinalBlock(); $cs.Close(); $out.Close(); $in.Close()
}
function Open-Vault($src,$pw){
    $zip=Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')+'.zip')
    Unprotect-File (Join-Path $src 'secure\vault.enc') $zip $pw
    $vault=Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')); EnsureDir $vault
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip,$vault); Remove-Item $zip -Force
    return $vault
}

# Curated AppData map comes from the UI thread (single source of truth); optional per-app selection.
function Get-AppDataMap {
    $all = @($sync.AppDataMap)
    if($sync.AppDataSel){ $sel=@($sync.AppDataSel); return @($all | Where-Object { $sel -contains $_.Name }) }
    return $all
}

# Browser roots: Chromium family keep per-profile 'Bookmarks' JSON; Firefox keeps places.sqlite per profile.
function Get-BrowserMap {
    @(
        @{ Name='Chrome';  Kind='chromium'; Root="$env:LOCALAPPDATA\Google\Chrome\User Data" }
        @{ Name='Edge';    Kind='chromium'; Root="$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
        @{ Name='Brave';   Kind='chromium'; Root="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
        @{ Name='Vivaldi'; Kind='chromium'; Root="$env:LOCALAPPDATA\Vivaldi\User Data" }
        @{ Name='Opera';   Kind='chromium'; Root="$env:APPDATA\Opera Software\Opera Stable" }
        @{ Name='Firefox'; Kind='firefox';  Root="$env:APPDATA\Mozilla\Firefox\Profiles" }
    )
}
function Get-ChromiumProfiles($root){ if(-not (Test-Path -LiteralPath $root)){ return @() }; @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }) }
function Get-FirefoxProfiles($root){ if(-not (Test-Path -LiteralPath $root)){ return @() }; @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'places.sqlite') }) }
function Get-FirefoxDefaultProfile($root){ $p=Get-FirefoxProfiles $root; if(-not $p){ $p=@(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) }; $d=$p | Where-Object { $_.Name -like '*.default-release' } | Select-Object -First 1; if(-not $d){ $d=$p | Select-Object -First 1 }; $d }

function Get-InstalledPrograms {
    $keys=@('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $seen=@{}; $list=@()
    foreach($k in $keys){
        foreach($e in (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)){
            if(-not $e.DisplayName -or $e.SystemComponent -eq 1 -or $e.ParentKeyName){ continue }
            $key="$($e.DisplayName)|$($e.DisplayVersion)"; if($seen[$key]){ continue }; $seen[$key]=$true
            $list += [pscustomobject]@{ Name=$e.DisplayName; Version=$e.DisplayVersion; Publisher=$e.Publisher; InstallLocation=$e.InstallLocation; UninstallString=$e.UninstallString }
        }
    }
    $list | Sort-Object Name
}
function Get-WslDistros { if(-not (CmdExists 'wsl')){ return @() }; @((& wsl -l -q 2>$null) | ForEach-Object { ($_ -replace "`0",'').Trim() } | Where-Object { $_ }) }

# Matches saved adapters to current ones (MAC first, then driver description) and lists only the settings that differ.
function Plan-NetAdapter($jsonPath){
    $saved=@(Get-Content $jsonPath -Raw | ConvertFrom-Json)
    $cur=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $plan=@{ Changes=@(); Unmatched=@(); Matched=0; Same=0 }
    foreach($s in $saved){
        $nic = $cur | Where-Object { $_.MacAddress -eq $s.Mac } | Select-Object -First 1
        if(-not $nic){ $nic = $cur | Where-Object { $_.InterfaceDescription -eq $s.Description } | Select-Object -First 1 }
        if(-not $nic){ $plan.Unmatched += $s.Name; continue }
        $plan.Matched++
        $have=@{}; foreach($p in @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword })){ $have[$p.RegistryKeyword]=$p }
        foreach($p in @($s.Properties)){
            $h=$have[$p.Keyword]; if(-not $h){ continue }
            if(([string]($h.RegistryValue -join ',')) -eq [string]$p.Value){ $plan.Same++; continue }
            $plan.Changes += @{ Nic=$nic.Name; Keyword=$p.Keyword; Value=[string]$p.Value; DisplayName=$p.DisplayName; DisplayValue=$p.DisplayValue; CurrentDisplay=$h.DisplayValue }
        }
    }
    $plan
}

# Live IP state for one adapter + family. DnsStatic comes from the registry NameServer value, which is the only reliable "DNS was set by hand" signal.
function Get-NetIPState($nic,$fam){
    $if=Get-NetIPInterface -InterfaceIndex $nic.InterfaceIndex -AddressFamily $fam -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $if){ return $null }
    $addrs=@(Get-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily $fam -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Manual' } | ForEach-Object { "{0}/{1}" -f $_.IPAddress,$_.PrefixLength } | Sort-Object)
    $gws=@(Get-NetRoute -InterfaceIndex $nic.InterfaceIndex -AddressFamily $fam -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -eq '::/0' } | ForEach-Object { $_.NextHop } | Sort-Object -Unique)
    $dns=@((Get-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily $fam -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ })
    $svc = if($fam -eq 'IPv4'){ 'Tcpip' } else { 'Tcpip6' }
    $ns = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc\Parameters\Interfaces\$($nic.InterfaceGuid)" -ErrorAction SilentlyContinue).NameServer
    @{ Family=$fam; Dhcp=($if.Dhcp -eq 'Enabled'); Addresses=$addrs; Gateways=$gws; Dns=$dns; DnsStatic=[bool]$ns }
}
# Matches saved adapters (MAC, then description) and lists the static IP / DNS settings that differ. DHCP families are counted, never changed.
function Plan-NetIP($jsonPath){
    $saved=@(Get-Content $jsonPath -Raw | ConvertFrom-Json)
    $cur=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $plan=@{ Changes=@(); Unmatched=@(); Matched=0; Same=0; Dhcp=0 }
    foreach($s in $saved){
        $nic = $cur | Where-Object { $_.MacAddress -eq $s.Mac } | Select-Object -First 1
        if(-not $nic){ $nic = $cur | Where-Object { $_.InterfaceDescription -eq $s.Description } | Select-Object -First 1 }
        if(-not $nic){ $plan.Unmatched += $s.Name; continue }
        $plan.Matched++
        foreach($f in @($s.Families)){
            $have=Get-NetIPState $nic $f.Family; if(-not $have){ continue }
            $sAddr=@($f.Addresses | Where-Object { $_ } | Sort-Object); $sGw=@($f.Gateways | Where-Object { $_ } | Sort-Object -Unique); $sDns=@($f.Dns | Where-Object { $_ })
            if($f.Dhcp){ $plan.Dhcp++ }
            elseif($sAddr.Count -gt 0){
                if($have.Dhcp -or (($have.Addresses -join ',') -ne ($sAddr -join ',')) -or (($have.Gateways -join ',') -ne ($sGw -join ','))){
                    $plan.Changes += @{ Nic=$nic.Name; Index=$nic.InterfaceIndex; Family=$f.Family; Kind='ip'; Addresses=$sAddr; Gateways=$sGw; Text=("{0} {1}: static {2}{3}" -f $nic.Name,$f.Family,($sAddr -join ', '),$(if($sGw.Count){ " via $($sGw -join ', ')" }else{ '' })) }
                } else { $plan.Same++ }
            }
            if($f.DnsStatic -and $sDns.Count -gt 0){
                if(($have.Dns -join ',') -ne ($sDns -join ',')){ $plan.Changes += @{ Nic=$nic.Name; Index=$nic.InterfaceIndex; Family=$f.Family; Kind='dns'; Dns=$sDns; Text=("{0} {1}: DNS {2} (now {3})" -f $nic.Name,$f.Family,($sDns -join ', '),$(if($have.Dns.Count){ $have.Dns -join ', ' }else{ 'automatic' })) } }
                else { $plan.Same++ }
            }
        }
        if($s.DnsSuffix){
            $curSuf=[string](Get-DnsClient -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue).ConnectionSpecificSuffix
            if($curSuf -ne [string]$s.DnsSuffix){ $plan.Changes += @{ Nic=$nic.Name; Index=$nic.InterfaceIndex; Family=''; Kind='suffix'; Suffix=[string]$s.DnsSuffix; Text=("{0}: DNS suffix {1}" -f $nic.Name,$s.DnsSuffix) } } else { $plan.Same++ }
        }
    }
    $plan
}

function Invoke-ModuleBackup($id,$root){
    $meta  = $sync.Meta[$id]
    $entry = @{ Id=$id; Name=$meta.Name; Cat=$meta.Cat; Secure=[bool]$meta.Sensitive; Size=0; Status='ok'; Note=''; Paths=@() }
    $userHome  = $env:USERPROFILE

    switch($id){
        'apps_winget' {
            $d = Join-Path $root 'apps'; EnsureDir $d
            if(CmdExists 'winget'){ & winget export -o (Join-Path $d 'winget-packages.json') --accept-source-agreements *>$null; WL '   winget list exported.'; try{ $n=@((Get-Content (Join-Path $d 'winget-packages.json') -Raw | ConvertFrom-Json).Sources.Packages).Count; $entry.Note="$n packages" }catch{} }
            else { $entry.Status='skip'; $entry.Note='winget not found' }
            $entry.Paths=@('apps\winget-packages.json')
        }
        'apps_ubundle' {
            $b = Join-Path ([Environment]::GetFolderPath('Desktop')) 'apps.ubundle'
            if(Test-Path -LiteralPath $b){ $d=Join-Path $root 'apps'; EnsureDir $d; Copy-Item $b (Join-Path $d 'apps.ubundle') -Force; $entry.Paths=@('apps\apps.ubundle') }
            else { $entry.Status='skip'; $entry.Note='no apps.ubundle on Desktop' }
        }
        'apps_inventory' {
            $d = Join-Path $root 'apps'; EnsureDir $d
            $list=@(Get-InstalledPrograms); $list | Export-Csv (Join-Path $d 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
            $entry.Note="$($list.Count) programs"; $entry.Paths=@('apps\installed-programs.csv')
        }
        'dev_vscode' {
            $d = Join-Path $root 'dev'; EnsureDir $d; $any=$false; $files=@()
            foreach($pair in @(@('code','vscode'),@('code-insiders','vscode-insiders'),@('cursor','cursor'))){
                if(CmdExists $pair[0]){ $f="{0}-extensions.txt" -f $pair[1]; & $pair[0] --list-extensions 2>$null | Set-Content -LiteralPath (Join-Path $d $f) -Encoding UTF8; $any=$true; $files+="dev\$f" }
            }
            if(-not $any){ $entry.Status='skip'; $entry.Note='no editors on PATH' } else { $entry.Paths=$files }
        }
        'dev_node' {
            $d = Join-Path $root 'dev'; EnsureDir $d; $any=$false; $files=@()
            if(CmdExists 'npm'){ & npm ls -g --depth=0 --json 2>$null | Set-Content -LiteralPath (Join-Path $d 'npm-globals.json') -Encoding UTF8; $any=$true; $files+='dev\npm-globals.json' }
            if(CmdExists 'nvm'){ & nvm list 2>$null | Set-Content -LiteralPath (Join-Path $d 'nvm-versions.txt') -Encoding UTF8; $any=$true; $files+='dev\nvm-versions.txt' }
            if(CmdExists 'fnm'){ & fnm list 2>$null | Set-Content -LiteralPath (Join-Path $d 'fnm-versions.txt') -Encoding UTF8; $any=$true; $files+='dev\fnm-versions.txt' }
            if(-not $any){ $entry.Status='skip'; $entry.Note='node/npm not found' } else { $entry.Paths=$files }
        }
        'dev_python' {
            $d = Join-Path $root 'dev\python'; EnsureDir $d; $any=$false
            if(CmdExists 'py'){
                $paths = & py -0p 2>$null
                foreach($line in $paths){ $exe=($line -replace '^\s*\S+\s+','').Trim(); if($exe -and (Test-Path -LiteralPath $exe)){ $tag=($line.Trim() -replace '^\s*(-V:|-)','' -replace '\s.*$','' -replace '[^\w\.\-]','_'); & $exe -m pip freeze 2>$null | Set-Content -LiteralPath (Join-Path $d "pip-$tag.txt") -Encoding UTF8; $any=$true } }
            } elseif(CmdExists 'python'){ & python -m pip freeze 2>$null | Set-Content -LiteralPath (Join-Path $d 'pip.txt') -Encoding UTF8; $any=$true }
            if(-not $any){ $entry.Status='skip'; $entry.Note='python not found' } else { $entry.Paths=@('dev\python') }
        }
        'dev_rust' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            if(CmdExists 'rustup'){ & rustup toolchain list 2>$null | Set-Content -LiteralPath (Join-Path $d 'rustup-toolchains.txt') -Encoding UTF8; & cargo install --list 2>$null | Set-Content -LiteralPath (Join-Path $d 'cargo-crates.txt') -Encoding UTF8; $entry.Paths=@('dev\rustup-toolchains.txt','dev\cargo-crates.txt') }
            else { $entry.Status='skip'; $entry.Note='rustup not found' }
        }
        'dev_dotnet' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            if(CmdExists 'dotnet'){ & dotnet tool list -g 2>$null | Set-Content -LiteralPath (Join-Path $d 'dotnet-tools.txt') -Encoding UTF8; $entry.Paths=@('dev\dotnet-tools.txt') }
            else { $entry.Status='skip'; $entry.Note='dotnet not found' }
        }
        'dev_git' {
            $d = Join-Path $root 'dev\git'; EnsureDir $d; $any=$false
            foreach($f in @('.gitconfig','.gitignore_global')){ $p=Join-Path $userHome $f; if(Test-Path -LiteralPath $p){ Copy-Item $p (Join-Path $d $f) -Force; $any=$true } }
            # Credentials go to the vault on their own so .gitconfig stays in the plain backup.
            $cred=Join-Path $userHome '.git-credentials'
            if(Test-Path -LiteralPath $cred){ $sd=Join-Path $root 'dev\git-credentials'; EnsureDir $sd; Copy-Item $cred (Join-Path $sd '.git-credentials') -Force; $entry.SecurePaths=@('dev\git-credentials'); $entry.Note='incl. credentials (vault)' }
            if(-not $any){ $entry.Status='skip'; $entry.Note='no .gitconfig' } else { $entry.Paths=@('dev\git') }
        }
        'dev_ssh' {
            $s = Join-Path $userHome '.ssh'
            if(Test-Path -LiteralPath $s){ $d=Join-Path $root 'dev\ssh'; Robo $s $d $false | Out-Null; $entry.Paths=@('dev\ssh'); $entry.Size=FolderSize $d }
            else { $entry.Status='skip'; $entry.Note='no ~/.ssh' }
        }
        'dev_ps' {
            $d = Join-Path $root 'dev\powershell'; EnsureDir $d
            if($PROFILE -and (Test-Path -LiteralPath $PROFILE)){ Copy-Item $PROFILE (Join-Path $d 'profile.ps1') -Force }
            try{ $mods=@(Get-InstalledModule -ErrorAction SilentlyContinue | Select-Object Name,Version); $mods | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $d 'modules.json') -Encoding UTF8; $entry.Note="$($mods.Count) modules" }catch{}
            $entry.Paths=@('dev\powershell')
        }
        'dev_wsl' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            if(CmdExists 'wsl'){ & wsl -l -v 2>$null | Set-Content -LiteralPath (Join-Path $d 'wsl-distros.txt') -Encoding UTF8; $entry.Note='list only'; $entry.Paths=@('dev\wsl-distros.txt') }
            else { $entry.Status='skip'; $entry.Note='wsl not found' }
        }
        'dev_wsl_export' {
            $distros=@(Get-WslDistros | Where-Object { $_ -notmatch '^docker-desktop' })
            if($distros.Count -eq 0){ $entry.Status='skip'; $entry.Note='no WSL distros' }
            else {
                $d=Join-Path $root 'dev\wsl'; EnsureDir $d
                foreach($n in $distros){ if($sync.Cancel){break}; WL "   exporting $n (this can take a while)..."; & wsl --export $n (Join-Path $d "$n.tar") *>$null }
                $entry.Note="$($distros.Count) distros"; $entry.Paths=@('dev\wsl'); $entry.Size=FolderSize $d
            }
        }
        'dev_env' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            [Environment]::GetEnvironmentVariables('User') | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $d 'env-user.json') -Encoding UTF8
            $entry.Paths=@('dev\env-user.json')
        }
        'win_wifi' {
            $d = Join-Path $root 'windows\wifi'; EnsureDir $d
            & netsh wlan export profile key=clear folder="$d" *>$null
            $n=(Get-ChildItem -LiteralPath $d -Filter *.xml -ErrorAction SilentlyContinue).Count
            if($n -eq 0){ $entry.Status='skip'; $entry.Note='no profiles' } else { $entry.Paths=@('windows\wifi'); $entry.Note="$n networks" }
        }
        'win_power' {
            $d = Join-Path $root 'windows\power'; EnsureDir $d
            $plans = & powercfg /list
            foreach($line in $plans){ if($line -match '([0-9a-f\-]{36})'){ $g=$Matches[1]; & powercfg /export (Join-Path $d "$g.pow") $g *>$null } }
            $entry.Paths=@('windows\power')
        }
        'win_netadapter' {
            $d = Join-Path $root 'windows'; EnsureDir $d; $out=@(); $changed=0
            try{
                foreach($nic in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)){
                    $props=@()
                    foreach($p in @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword })){
                        $val=[string]($p.RegistryValue -join ','); $def=[string]($p.DefaultRegistryValue -join ',')
                        if($def -ne '' -and $val -ne $def){ $changed++ }
                        $props += @{ Keyword=$p.RegistryKeyword; DisplayName=$p.DisplayName; Value=$val; DisplayValue=$p.DisplayValue; Default=$def }
                    }
                    if($props.Count -gt 0){ $out += @{ Name=$nic.Name; Description=$nic.InterfaceDescription; Mac=$nic.MacAddress; Properties=$props } }
                }
            }catch{}
            if($out.Count -eq 0){ $entry.Status='skip'; $entry.Note='no adapters' }
            else { ($out | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $d 'netadapters.json') -Encoding UTF8; $entry.Paths=@('windows\netadapters.json'); $entry.Note="$($out.Count) adapters, $changed non-default settings" }
        }
        'win_netip' {
            $d = Join-Path $root 'windows'; EnsureDir $d; $out=@(); $static=0; $dnsStatic=0
            try{
                foreach($nic in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)){
                    $fams=@()
                    foreach($fam in 'IPv4','IPv6'){ $s=Get-NetIPState $nic $fam; if($s){ $fams+=$s; if(-not $s.Dhcp -and $s.Addresses.Count){ $static++ }; if($s.DnsStatic){ $dnsStatic++ } } }
                    $dc=Get-DnsClient -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue
                    $out += @{ Name=$nic.Name; Description=$nic.InterfaceDescription; Mac=$nic.MacAddress; Families=$fams; DnsSuffix=[string]$dc.ConnectionSpecificSuffix }
                }
            }catch{}
            if($out.Count -eq 0){ $entry.Status='skip'; $entry.Note='no adapters' }
            else { ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $d 'netip.json') -Encoding UTF8; $entry.Paths=@('windows\netip.json'); $entry.Note="$($out.Count) adapters, $static static IP, $dnsStatic custom DNS" }
        }
        'win_drives' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            try{ $m=@(Get-SmbMapping -ErrorAction SilentlyContinue | Select-Object LocalPath,RemotePath); $m | Export-Csv (Join-Path $d 'drives.csv') -NoTypeInformation; $entry.Note="$($m.Count) drives" }catch{}
            $entry.Paths=@('windows\drives.csv')
        }
        'win_hosts' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            $h = "$env:WINDIR\System32\drivers\etc\hosts"; if(Test-Path -LiteralPath $h){ Copy-Item $h (Join-Path $d 'hosts') -Force }
            $entry.Paths=@('windows\hosts')
        }
        'win_tasks' {
            $d = Join-Path $root 'windows\tasks'; EnsureDir $d; $n=0; $map=@()
            try{ foreach($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft*' -and $_.TaskPath -ne '\' })){ $xml=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath; $safe=("{0}_{1}" -f ($t.TaskPath.Trim('\') -replace '[^\w\.\-]','_'),($t.TaskName -replace '[^\w\.\-]','_')); $xml | Set-Content -LiteralPath (Join-Path $d "$safe.xml") -Encoding UTF8; $map += @{ File="$safe.xml"; TaskName=$t.TaskName; TaskPath=$t.TaskPath }; $n++ } }catch{}
            if($n -eq 0){ $entry.Status='skip'; $entry.Note='none found' } else { ($map | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $d 'tasks.json') -Encoding UTF8; $entry.Paths=@('windows\tasks'); $entry.Note="$n tasks" }
        }
        'win_explorer' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            & reg export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' (Join-Path $d 'explorer-advanced.reg') /y *>$null
            $entry.Paths=@('windows\explorer-advanced.reg')
        }
        'win_terminal' {
            $d = Join-Path $root 'windows'; EnsureDir $d; $any=$false
            foreach($p in @("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json","$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json","$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json")){ if(Test-Path -LiteralPath $p){ Copy-Item $p (Join-Path $d 'terminal-settings.json') -Force; $any=$true; break } }
            if(-not $any){ $entry.Status='skip'; $entry.Note='no settings.json' } else { $entry.Paths=@('windows\terminal-settings.json') }
        }
        'win_printers' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            try{ Get-Printer -ErrorAction SilentlyContinue | Select-Object Name,DriverName,PortName,Shared | Export-Csv (Join-Path $d 'printers.csv') -NoTypeInformation }catch{}
            $entry.Note='list only'; $entry.Paths=@('windows\printers.csv')
        }
        'win_defaultapps' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            try{ & Dism.exe /Online /Export-DefaultAppAssociations:(Join-Path $d 'default-apps.xml') *>$null; if($LASTEXITCODE -ne 0){ $entry.Status='skip'; $entry.Note='needs admin' } else { $entry.Paths=@('windows\default-apps.xml') } }catch{ $entry.Status='skip'; $entry.Note='needs admin' }
        }
        'win_fonts' {
            $s = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
            if((Test-Path -LiteralPath $s) -and @(Get-ChildItem -LiteralPath $s -File -ErrorAction SilentlyContinue).Count -gt 0){ $d=Join-Path $root 'windows\fonts'; Robo $s $d $false | Out-Null; $entry.Paths=@('windows\fonts'); $entry.Size=FolderSize $d; $entry.Note="$(@(Get-ChildItem -LiteralPath $d -File).Count) files" } else { $entry.Status='skip'; $entry.Note='none' }
        }
        'app_appdata' {
            $base = Join-Path $root 'appdata'; $names=@()
            foreach($app in (Get-AppDataMap)){ if(Test-Path -LiteralPath $app.Src){ Robo $app.Src (Join-Path $base $app.Name) (-not $sync.AppDataFull) | Out-Null; $names+=$app.Name } }
            if($names.Count -eq 0){ $entry.Status='skip'; $entry.Note='no known app configs' } else { $entry.Paths=@($names | ForEach-Object { "appdata\$_" }); $entry.Note=($names -join ', ') }
        }
        'app_bookmarks' {
            $base=Join-Path $root 'appdata\browsers\bookmarks'; $n=0
            foreach($b in (Get-BrowserMap)){
                if($b.Kind -eq 'chromium'){
                    if($b.Name -eq 'Opera'){ $f=Join-Path $b.Root 'Bookmarks'; if(Test-Path -LiteralPath $f){ $d=Join-Path $base 'Opera\Default'; EnsureDir $d; Copy-Item $f $d -Force; $n++ } }
                    else { foreach($p in (Get-ChromiumProfiles $b.Root)){ $f=Join-Path $p.FullName 'Bookmarks'; if(Test-Path -LiteralPath $f){ $d=Join-Path $base ("{0}\{1}" -f $b.Name,$p.Name); EnsureDir $d; Copy-Item $f $d -Force; $n++ } } }
                } else {
                    foreach($p in (Get-FirefoxProfiles $b.Root)){ $d=Join-Path $base ("Firefox\{0}" -f $p.Name); EnsureDir $d; foreach($f in @('places.sqlite','favicons.sqlite')){ $fp=Join-Path $p.FullName $f; if(Test-Path -LiteralPath $fp){ Copy-Item $fp $d -Force } }; $n++ }
                }
            }
            if($n -eq 0){ $entry.Status='skip'; $entry.Note='no browsers found' } else { $entry.Paths=@('appdata\browsers\bookmarks'); $entry.Note="$n profiles" }
        }
        'app_browserprofiles' {
            $base=Join-Path $root 'appdata\browsers\profiles'; $names=@()
            foreach($b in (Get-BrowserMap)){ if(Test-Path -LiteralPath $b.Root){ Robo $b.Root (Join-Path $base $b.Name) $true | Out-Null; $names+=$b.Name } }
            if($names.Count -eq 0){ $entry.Status='skip'; $entry.Note='no browsers found' } else { $entry.Paths=@('appdata\browsers\profiles'); $entry.Note=($names -join ', ')+' (saved passwords/cookies are machine-bound and will not carry over)'; $entry.Size=FolderSize $base }
        }
        'app_putty' {
            $d = Join-Path $root 'appdata\putty'; EnsureDir $d
            & reg export 'HKCU\Software\SimonTatham' (Join-Path $d 'putty.reg') /y *>$null
            if($LASTEXITCODE -ne 0){ $entry.Status='skip'; $entry.Note='no PuTTY data' } else { $entry.Paths=@('appdata\putty') }
        }
        'user_custom' {
            $folders=@($sync.Custom | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
            if($folders.Count -eq 0){ $entry.Status='skip'; $entry.Note='no custom folders' }
            else {
                $base=Join-Path $root 'userfolders\custom'; EnsureDir $base; $map=@(); $i=0
                foreach($f in $folders){ if($sync.Cancel){break}; $i++; $leaf=(Split-Path $f -Leaf) -replace '[^\w\.\-]','_'; $rel="{0:D2}_{1}" -f $i,$leaf; WL "   $f"; Robo $f (Join-Path $base $rel) $false | Out-Null; $map += @{ Rel=$rel; Original=$f } }
                ($map | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $base 'map.json') -Encoding UTF8
                $entry.Paths=@('userfolders\custom'); $entry.Note="$($folders.Count) folders"; $entry.Size=FolderSize $base
            }
        }
        default {
            if($id -like 'user_*'){
                $src=UserFolderPath $id
                if($src -and (Test-Path -LiteralPath $src)){ $d=Join-Path $root ("userfolders\{0}" -f $Script:UserLeaf[$id]); Robo $src $d $false | Out-Null; $entry.Paths=@((RelOf $root $d)); $entry.Size=FolderSize $d }
                else { $entry.Status='skip'; $entry.Note='folder missing' }
            }
        }
    }
    if($entry.Size -eq 0 -and $entry.Paths.Count -gt 0){ $tot=0; foreach($rp in $entry.Paths){ $tot += FolderSize (Join-Path $root $rp) }; $entry.Size=$tot }
    return $entry
}

function Get-SecureRelPaths($entries){
    $rels=@()
    foreach($e in $entries){ if($e.Status -eq 'skip' -or $e.Status -eq 'error'){ continue }; if($e.Secure){ $rels += @($e.Paths) }; if($e.SecurePaths){ $rels += @($e.SecurePaths) } }
    @($rels | Where-Object { $_ } | Select-Object -Unique)
}
function Protect-Secure($root,$rels,$pw){
    $stage = Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')); EnsureDir $stage
    foreach($rel in $rels){ $full=Join-Path $root $rel; if(Test-Path -LiteralPath $full){ $tp=Join-Path $stage $rel; EnsureDir (Split-Path $tp -Parent); Copy-Item -LiteralPath $full -Destination $tp -Recurse -Force } }
    $zip = Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')+'.zip')
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
    EnsureDir (Join-Path $root 'secure')
    Protect-File $zip (Join-Path $root 'secure\vault.enc') $pw
    Remove-Item $zip -Force -ErrorAction SilentlyContinue; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    foreach($rel in $rels){ $full=Join-Path $root $rel; if(Test-Path -LiteralPath $full){ Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue } }
}

$Script:MetaFiles=@('manifest.json','checksums.sha256','phoenix.log','compare.txt')
function Write-Checksums($root){
    $files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $Script:MetaFiles -notcontains $_.Name -or $_.DirectoryName -ne $root })
    $sb=New-Object System.Text.StringBuilder; $i=0; $ok=0; $n=[math]::Max(1,$files.Count); $Script:HashFails=0; $Script:HashLastError=''
    foreach($f in $files){
        if($sync.Cancel){ break }
        $i++; if(($i % 200) -eq 0){ Prog (96 + [int](3*$i/$n)) "Hashing $i / $($files.Count) files" }
        $h=FileHash $f.FullName; if($h){ $ok++; $null=$sb.AppendLine(("{0} *{1}" -f $h,(RelOf $root $f.FullName))) }
    }
    if($ok -eq 0 -and $files.Count -gt 0){ throw "no file could be hashed ($($files.Count) files; last error: $Script:HashLastError)" }
    [System.IO.File]::WriteAllText((Join-Path $root 'checksums.sha256'),$sb.ToString(),(New-Object System.Text.UTF8Encoding($false)))
    if($Script:HashFails -gt 0){ WL "   $Script:HashFails files could not be hashed (last: $Script:HashLastError)" 'Warn' }
    return $ok
}

function Start-BackupRun {
    $dest=$sync.Dest; $ids=@($sync.Ids); $enc=$sync.Encrypt; $pw=$sync.Password
    $root=$null
    if($sync.UpdateExisting){
        $prev=@(Get-ChildItem -LiteralPath $dest -Directory -Filter ("Phoenix-Backup-{0}-*" -f $env:COMPUTERNAME) -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending)
        if($prev.Count -gt 0){ $root=$prev[0].FullName; $sync.Mirror=$true; WL "Updating existing backup: $root" 'Info' } else { WL 'No previous backup found here - creating a new one.' 'Warn' }
    }
    if(-not $root){ $stamp = Get-Date -Format 'yyyyMMdd-HHmm'; $root = Join-Path $dest ("Phoenix-Backup-{0}-{1}" -f $env:COMPUTERNAME,$stamp) }
    # Remember what we are about to overwrite / what came before, so the end report can say what changed since last time.
    $prevSnap=$null; $prevRoot=$null; $prevLabel=$null
    try{
        if($sync.Mirror){ $prevSnap=Snapshot-BackupMeta $root; $prevLabel="previous run ($(([datetime](Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json).Created).ToString('g')))" }
        else { $prev=@(Get-ChildItem -LiteralPath $dest -Directory -Filter 'Phoenix-Backup-*' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $root -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')) } | Sort-Object Name -Descending); if($prev.Count -gt 0){ $prevRoot=$prev[0].FullName; $prevLabel=$prev[0].Name } }
    }catch{ $prevSnap=$null; $prevRoot=$null }
    EnsureDir $root; $sync.OutputPath=$root; $sync.LogPath=Join-Path $root 'phoenix.log'
    if($sync.Mirror){ Remove-Item -LiteralPath (Join-Path $root 'secure') -Recurse -Force -ErrorAction SilentlyContinue }
    WL ("Phoenix backup started {0} on {1} ({2})" -f (Get-Date).ToString('g'),$env:COMPUTERNAME,$env:USERNAME)
    $man = @{ Tool='Phoenix'; Version='1.2'; Machine=$env:COMPUTERNAME; User=$env:USERNAME; Created=(Get-Date).ToString('o'); Encrypted=[bool]$enc; Modules=@(); Log='phoenix.log' }
    $total=$ids.Count; $i=0; $report=@()
    foreach($id in $ids){
        if($sync.Cancel){ WL 'Cancelled.' 'Warn'; break }
        $i++; $nm=$sync.Meta[$id].Name; Prog ([int](($i-1)/$total*92)) "Backing up: $nm"; WL "-> $nm"
        try{
            $e = Invoke-ModuleBackup $id $root
            $man.Modules += $e
            if($e.Status -eq 'skip'){ WL ("   skipped ({0})" -f $e.Note) 'Warn'; $report += @{ Name=$nm; Status='skip'; Note=$e.Note } }
            else { WL ("   done  {0}" -f (Fmt-Bytes $e.Size)) 'Ok'; $report += @{ Name=$nm; Status='ok'; Note=(@($e.Note,(Fmt-Bytes $e.Size)) | Where-Object { $_ }) -join '  -  ' } }
        }catch{ WL ("   FAILED: {0}" -f $_.Exception.Message) 'Error'; $man.Modules += @{ Id=$id; Name=$nm; Status='error'; Note=$_.Exception.Message; Paths=@() }; $report += @{ Name=$nm; Status='error'; Note=$_.Exception.Message } }
    }
    $secure = Get-SecureRelPaths $man.Modules
    if($enc -and $secure.Count -gt 0 -and $pw){ Prog 94 'Encrypting sensitive data...'; try{ Protect-Secure $root $secure $pw; $man.Vault='secure/vault.enc'; $man.VaultFormat=2; $man.SecurePaths=$secure; WL '   sensitive data encrypted to vault.enc' 'Ok' }catch{ WL "Encryption failed: $($_.Exception.Message)" 'Error'; $report += @{ Name='Vault'; Status='error'; Note=$_.Exception.Message } } }
    elseif($secure.Count -gt 0){ WL 'NOTE: sensitive data stored UNENCRYPTED (vault was off).' 'Warn'; $report += @{ Name='Vault'; Status='skip'; Note='sensitive data left unencrypted' } }
    if(-not $sync.NoChecksums -and -not $sync.Cancel){ Prog 96 'Writing checksums...'; try{ $n=Write-Checksums $root; $man.Checksums='checksums.sha256'; WL "   checksums written for $n files" 'Ok' }catch{ WL "Checksums failed: $($_.Exception.Message)" 'Error'; $report += @{ Name='Checksums'; Status='error'; Note=$_.Exception.Message }; Remove-Item -LiteralPath (Join-Path $root 'checksums.sha256') -Force -ErrorAction SilentlyContinue } }
    $man.Completed=(Get-Date).ToString('o'); $man.Cancelled=[bool]$sync.Cancel
    ($man | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding UTF8
    $cmpOld = if($prevSnap){ $prevSnap } elseif($prevRoot){ $prevRoot } else { $null }
    if($cmpOld -and -not $sync.Cancel){
        Prog 99 'Comparing with previous backup...'; WL "-> Changes since $prevLabel"
        try{ $r=Compare-Backups $cmpOld $root $prevLabel (Split-Path $root -Leaf) ([bool]$prevSnap) $false; Write-CompareFile $root $r.Text | Out-Null; WL "   $($r.Summary)  -  details in compare.txt" $(if($r.Any){'Warn'}else{'Ok'}); $report += @{ Name='Changes since last backup'; Status=$(if($r.Any){'changed'}else{'ok'}); Note="$($r.Summary)  -  details in compare.txt" } }
        catch{ WL "   compare skipped: $($_.Exception.Message)" 'Warn' }
    }
    if($prevSnap){ Remove-Item -LiteralPath $prevSnap -Recurse -Force -ErrorAction SilentlyContinue }
    Prog 100 'Backup complete'; WL "Saved to: $root" 'Ok'; $sync.Result='backup'
    Emit 'Report' @{ Title=$(if($sync.Cancel){'Backup cancelled'}else{'Backup complete'}); Items=$report }
}

# Resolve a backup-relative path: from the decrypted vault when it lives there, else from the plain backup.
$Script:RSrc=$null; $Script:RVault=$null
function P($rel){ if($Script:RVault){ $v=Join-Path $Script:RVault $rel; if(Test-Path -LiteralPath $v){ return $v } }; Join-Path $Script:RSrc $rel }

function Register-UserFonts($dir){
    $reg='HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'; if(-not (Test-Path $reg)){ New-Item -Path $reg -Force | Out-Null }
    $n=0
    foreach($f in (Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -match '^\.(ttf|otf|ttc)$' })){
        $title=$null
        try{ $pfc=New-Object System.Drawing.Text.PrivateFontCollection; $pfc.AddFontFile($f.FullName); if($pfc.Families.Count -gt 0){ $title=$pfc.Families[0].Name }; $pfc.Dispose() }catch{}
        if(-not $title){ $title=$f.BaseName }
        $key = if($f.Extension -ieq '.otf'){ "$title (OpenType)" } else { "$title (TrueType)" }
        New-ItemProperty -Path $reg -Name $key -Value $f.FullName -PropertyType String -Force | Out-Null; $n++
    }
    return $n
}

function Invoke-ModuleRestore($id,$src){
    $userHome=$env:USERPROFILE
    switch($id){
        'apps_winget' { $f=P 'apps\winget-packages.json'; if((Test-Path -LiteralPath $f) -and (CmdExists 'winget')){ WL '   importing apps (this can take a while)...'; & winget import -i $f --accept-package-agreements --accept-source-agreements --ignore-unavailable --ignore-versions *>$null; Note 'winget import finished - check the log for packages that were unavailable' } elseif(-not (CmdExists 'winget')){ Manual 'winget not installed - install App Installer from the Store, then re-run' } }
        'apps_inventory' {
            $f=P 'apps\installed-programs.csv'
            if(Test-Path -LiteralPath $f){ $old=@(Import-Csv $f); $cur=@{}; foreach($p in (Get-InstalledPrograms)){ $cur[$p.Name.ToLower()]=$true }; $missing=@($old | Where-Object { -not $cur[$_.Name.ToLower()] }); Manual ("{0} of {1} programs not installed here - see apps\installed-programs.csv" -f $missing.Count,$old.Count); foreach($m in ($missing | Select-Object -First 40)){ WL ("   missing: {0} {1}" -f $m.Name,$m.Version) }; if($missing.Count -gt 40){ WL ("   ... and {0} more" -f ($missing.Count-40)) } }
        }
        'dev_vscode'  { $n=0; foreach($pair in @(@('code','vscode'),@('code-insiders','vscode-insiders'),@('cursor','cursor'))){ $f=P ("dev\{0}-extensions.txt" -f $pair[1]); if((Test-Path -LiteralPath $f) -and (CmdExists $pair[0])){ foreach($ext in (Get-Content $f)){ if($ext.Trim()){ & $pair[0] --install-extension $ext.Trim() --force *>$null; $n++ } } } elseif(Test-Path -LiteralPath $f){ WL ("   {0} not installed yet - extensions skipped" -f $pair[0]) 'Warn' } }; Note "$n extensions installed" }
        'dev_node'    { $f=P 'dev\npm-globals.json'; if((Test-Path -LiteralPath $f) -and (CmdExists 'npm')){ try{ $j=Get-Content $f -Raw | ConvertFrom-Json; $n=0; if($j.dependencies){ foreach($p in $j.dependencies.PSObject.Properties.Name){ if($p -ne 'npm' -and $p -ne 'corepack'){ & npm i -g $p *>$null; $n++ } } }; Note "$n packages" }catch{} } elseif(Test-Path -LiteralPath $f){ Manual 'npm not installed - install Node first, then re-run this item' } }
        'dev_python'  {
            $d=P 'dev\python'
            if(Test-Path -LiteralPath $d){
                $n=0
                foreach($f in (Get-ChildItem -LiteralPath $d -Filter 'pip*.txt')){
                    $ver = if($f.BaseName -match '(\d+\.\d+)'){ $Matches[1] } else { $null }
                    if($ver -and (CmdExists 'py')){ WL "   pip install for Python $ver..."; & py "-$ver" -m pip install -r $f.FullName --quiet *>$null; if($LASTEXITCODE -eq 0){ $n++ } else { WL "   Python $ver not installed here - skipped $($f.Name)" 'Warn' } }
                    elseif(CmdExists 'python'){ & python -m pip install -r $f.FullName --quiet *>$null; $n++ }
                }
                if($n -eq 0){ Manual 'Python not installed yet - re-run this item after installing Python' } else { Note "$n requirement files installed" }
            }
        }
        'dev_rust'    { $f=P 'dev\cargo-crates.txt'; if((Test-Path -LiteralPath $f) -and (CmdExists 'cargo')){ $n=0; foreach($line in (Get-Content $f)){ if($line -match '^(\S+)\s+v'){ & cargo install $Matches[1] *>$null; $n++ } }; Note "$n crates" } elseif(Test-Path -LiteralPath $f){ Manual 'cargo not installed - install rustup first' } }
        'dev_dotnet'  { $f=P 'dev\dotnet-tools.txt'; if((Test-Path -LiteralPath $f) -and (CmdExists 'dotnet')){ $n=0; foreach($line in (Get-Content $f | Select-Object -Skip 2)){ $c=($line -split '\s+')[0]; if($c){ & dotnet tool install -g $c *>$null; $n++ } }; Note "$n tools" } elseif(Test-Path -LiteralPath $f){ Manual 'dotnet SDK not installed' } }
        'dev_git'     {
            $g=P 'dev\git'; if(Test-Path -LiteralPath $g){ foreach($f in (Get-ChildItem -LiteralPath $g -File)){ Copy-Item $f.FullName (Join-Path $userHome $f.Name) -Force } }
            foreach($c in @((P 'dev\git-credentials\.git-credentials'),(P 'dev\git\.git-credentials'))){ if(Test-Path -LiteralPath $c){ Copy-Item $c (Join-Path $userHome '.git-credentials') -Force; Note 'config + credentials'; break } }
        }
        'dev_ssh'     { $s=P 'dev\ssh'; if(Test-Path -LiteralPath $s){ $dst=Join-Path $userHome '.ssh'; Robo $s $dst $false | Out-Null; try{ & icacls $dst /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" *>$null }catch{}; Note 'keys restored, permissions tightened' } }
        'dev_ps'      {
            $p=P 'dev\powershell\profile.ps1'; if((Test-Path -LiteralPath $p) -and $PROFILE){ EnsureDir (Split-Path $PROFILE -Parent); Copy-Item $p $PROFILE -Force }
            $m=P 'dev\powershell\modules.json'
            if(Test-Path -LiteralPath $m){ try{ $mods=@(Get-Content $m -Raw | ConvertFrom-Json); $have=@{}; foreach($x in (Get-Module -ListAvailable -ErrorAction SilentlyContinue)){ $have[$x.Name]=$true }; $n=0; foreach($mod in $mods){ if($mod.Name -and -not $have[$mod.Name]){ WL "   Install-Module $($mod.Name)"; try{ Install-Module -Name $mod.Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop; $n++ }catch{ WL "   $($mod.Name) failed: $($_.Exception.Message)" 'Warn' } } }; Note "profile + $n modules installed" }catch{} }
        }
        'dev_env'     { $f=P 'dev\env-user.json'; if(Test-Path -LiteralPath $f){ try{ $j=Get-Content $f -Raw | ConvertFrom-Json; $n=0; foreach($k in $j.PSObject.Properties.Name){ if($k -eq 'Path'){ $cur=[Environment]::GetEnvironmentVariable('Path','User'); $merged=(@($cur -split ';') + @($j.$k -split ';') | Where-Object { $_ } | Select-Object -Unique) -join ';'; [Environment]::SetEnvironmentVariable('Path',$merged,'User') } else { [Environment]::SetEnvironmentVariable($k,$j.$k,'User') }; $n++ }; Note "$n variables (PATH merged)" }catch{} } }
        'dev_wsl_export' {
            $d=P 'dev\wsl'
            if((Test-Path -LiteralPath $d) -and (CmdExists 'wsl')){
                $have=@(Get-WslDistros); $n=0
                foreach($t in (Get-ChildItem -LiteralPath $d -Filter *.tar)){ $name=$t.BaseName; if($have -contains $name){ WL "   $name already exists - skipped" 'Warn'; continue }; $loc=Join-Path $env:LOCALAPPDATA "WSL\$name"; EnsureDir $loc; WL "   importing $name..."; & wsl --import $name $loc $t.FullName *>$null; if($LASTEXITCODE -eq 0){ $n++ } else { WL "   import of $name failed (is WSL enabled?)" 'Warn' } }
                if($n -eq 0 -and $have.Count -eq 0){ Manual 'WSL not enabled - run "wsl --install", reboot, then re-run this item' } else { Note "$n distros imported (default user may need: <distro> config --default-user <name>)" }
            } elseif(Test-Path -LiteralPath $d){ Manual 'wsl.exe missing - enable WSL first' }
        }
        'win_wifi'    { $d=P 'windows\wifi'; if(Test-Path -LiteralPath $d){ $n=0; foreach($x in (Get-ChildItem -LiteralPath $d -Filter *.xml)){ & netsh wlan add profile filename="$($x.FullName)" user=all *>$null; if($LASTEXITCODE -eq 0){ $n++ } }; if($n -eq 0){ Manual 'no profiles imported - needs admin or a Wi-Fi adapter' } else { Note "$n networks" } } }
        'win_power'   { $d=P 'windows\power'; if(Test-Path -LiteralPath $d){ $n=0; foreach($x in (Get-ChildItem -LiteralPath $d -Filter *.pow)){ & powercfg /import $x.FullName *>$null; $n++ }; Note "$n plans imported" } }
        'win_netadapter' {
            $f=P 'windows\netadapters.json'
            if(Test-Path -LiteralPath $f){
                $plan=Plan-NetAdapter $f
                if($plan.Unmatched.Count -gt 0){ WL "   no matching adapter for: $($plan.Unmatched -join ', ')" 'Warn' }
                $n=0; $fail=0
                foreach($c in $plan.Changes){ try{ Set-NetAdapterAdvancedProperty -Name $c.Nic -RegistryKeyword $c.Keyword -RegistryValue $c.Value -NoRestart -ErrorAction Stop; $n++; WL "   $($c.Nic): $($c.DisplayName) -> $($c.DisplayValue)" }catch{ $fail++; WL "   $($c.Nic): $($c.DisplayName) failed: $($_.Exception.Message)" 'Warn' } }
                foreach($nic in @($plan.Changes | ForEach-Object { $_.Nic } | Select-Object -Unique)){ try{ Restart-NetAdapter -Name $nic -ErrorAction SilentlyContinue }catch{} }
                if($fail -gt 0){ Manual "$n applied, $fail failed (needs admin)" } elseif($plan.Changes.Count -eq 0){ Note 'all settings already match' } else { Note "$n settings applied on $(@($plan.Changes | ForEach-Object { $_.Nic } | Select-Object -Unique).Count) adapters" }
            }
        }
        'win_netip' {
            $f=P 'windows\netip.json'
            if(Test-Path -LiteralPath $f){
                $plan=Plan-NetIP $f
                if($plan.Unmatched.Count -gt 0){ WL "   no matching adapter for: $($plan.Unmatched -join ', ')" 'Warn' }
                $n=0; $fail=0
                foreach($c in $plan.Changes){
                    try{
                        switch($c.Kind){
                            'ip' {
                                $pfx = if($c.Family -eq 'IPv4'){ '0.0.0.0/0' } else { '::/0' }
                                Set-NetIPInterface -InterfaceIndex $c.Index -AddressFamily $c.Family -Dhcp Disabled -ErrorAction Stop
                                Get-NetIPAddress -InterfaceIndex $c.Index -AddressFamily $c.Family -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Manual' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                                Get-NetRoute -InterfaceIndex $c.Index -AddressFamily $c.Family -DestinationPrefix $pfx -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                                $first=$true
                                foreach($a in @($c.Addresses)){
                                    $ip,$pl = $a -split '/'
                                    $na=@{ InterfaceIndex=$c.Index; IPAddress=$ip; PrefixLength=[int]$pl; ErrorAction='Stop' }
                                    if($first -and @($c.Gateways).Count -gt 0){ $na.DefaultGateway=@($c.Gateways)[0] }
                                    New-NetIPAddress @na | Out-Null; $first=$false
                                }
                                foreach($g in @(@($c.Gateways) | Select-Object -Skip 1)){ New-NetRoute -InterfaceIndex $c.Index -DestinationPrefix $pfx -NextHop $g -ErrorAction SilentlyContinue | Out-Null }
                            }
                            'dns'    { Set-DnsClientServerAddress -InterfaceIndex $c.Index -ServerAddresses @($c.Dns) -ErrorAction Stop }
                            'suffix' { Set-DnsClient -InterfaceIndex $c.Index -ConnectionSpecificSuffix $c.Suffix -ErrorAction Stop }
                        }
                        $n++; WL "   $($c.Text)"
                    }catch{ $fail++; WL "   $($c.Text) failed: $($_.Exception.Message)" 'Warn' }
                }
                if($fail -gt 0){ Manual "$n applied, $fail failed (needs admin)" } elseif($plan.Changes.Count -eq 0){ Note "all settings already match ($($plan.Dhcp) DHCP adapters left alone)" } else { Note "$n settings applied ($($plan.Dhcp) DHCP adapters left alone)" }
            }
        }
        'win_hosts'   { $f=P 'windows\hosts'; if(Test-Path -LiteralPath $f){ try{ Copy-Item $f "$env:WINDIR\System32\drivers\etc\hosts" -Force -ErrorAction Stop }catch{ Manual 'hosts file needs admin - re-run elevated' } } }
        'win_tasks'   {
            $d=P 'windows\tasks'
            if(Test-Path -LiteralPath $d){
                $map=@{}; $mf=Join-Path $d 'tasks.json'; if(Test-Path -LiteralPath $mf){ try{ foreach($m in @(Get-Content $mf -Raw | ConvertFrom-Json)){ $map[$m.File]=$m } }catch{} }
                $n=0; $fail=0
                foreach($x in (Get-ChildItem -LiteralPath $d -Filter *.xml)){ $m=$map[$x.Name]; $tn=if($m){$m.TaskName}else{[IO.Path]::GetFileNameWithoutExtension($x.Name)}; $tp=if($m){$m.TaskPath}else{'\'}; try{ Register-ScheduledTask -Xml (Get-Content $x.FullName -Raw) -TaskName $tn -TaskPath $tp -Force -ErrorAction Stop *>$null; $n++ }catch{ $fail++; WL "   $tn failed: $($_.Exception.Message)" 'Warn' } }
                if($fail -gt 0){ Manual "$n registered, $fail failed (admin needed or user SID changed)" } else { Note "$n tasks registered" }
            }
        }
        'win_explorer'{ $f=P 'windows\explorer-advanced.reg'; if(Test-Path -LiteralPath $f){ & reg import $f *>$null; Note 'sign out to apply' } }
        'win_terminal'{
            $f=P 'windows\terminal-settings.json'
            if(Test-Path -LiteralPath $f){
                $targets=@("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState","$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState","$env:LOCALAPPDATA\Microsoft\Windows Terminal")
                $hit=@($targets | Where-Object { Test-Path -LiteralPath $_ })
                if($hit.Count -eq 0){ $hit=@($targets[2]); EnsureDir $targets[2] }
                foreach($t in $hit){ Copy-Item $f (Join-Path $t 'settings.json') -Force }
                Note ("written to {0} location(s)" -f $hit.Count)
            }
        }
        'win_defaultapps'{ $f=P 'windows\default-apps.xml'; if(Test-Path -LiteralPath $f){ try{ & Dism.exe /Online /Import-DefaultAppAssociations:$f *>$null; if($LASTEXITCODE -ne 0){ Manual 'needs admin' } }catch{ Manual 'needs admin' } } }
        'win_fonts'   { $d=P 'windows\fonts'; if(Test-Path -LiteralPath $d){ $dst="$env:LOCALAPPDATA\Microsoft\Windows\Fonts"; Robo $d $dst $false | Out-Null; $n=Register-UserFonts $dst; Note "$n fonts registered (sign out to see them everywhere)" } }
        'app_appdata' { $n=0; foreach($app in @($sync.AppDataMap)){ $s=P ("appdata\{0}" -f $app.Name); if(Test-Path -LiteralPath $s){ EnsureDir $app.Src; Robo $s $app.Src $false | Out-Null; $n++ } }; Note "$n apps (close & reopen them)" }
        'app_bookmarks' {
            $base=P 'appdata\browsers\bookmarks'
            if(Test-Path -LiteralPath $base){
                $n=0
                foreach($b in (Get-BrowserMap)){
                    $bd=Join-Path $base $b.Name; if(-not (Test-Path -LiteralPath $bd)){ continue }
                    if($b.Kind -eq 'chromium'){
                        foreach($p in (Get-ChildItem -LiteralPath $bd -Directory)){ $f=Join-Path $p.FullName 'Bookmarks'; if(-not (Test-Path -LiteralPath $f)){ continue }; $dst = if($b.Name -eq 'Opera'){ $b.Root } else { Join-Path $b.Root $p.Name }; EnsureDir $dst; Copy-Item $f (Join-Path $dst 'Bookmarks') -Force; Remove-Item (Join-Path $dst 'Bookmarks.bak') -Force -ErrorAction SilentlyContinue; $n++ }
                    } else {
                        $target=Get-FirefoxDefaultProfile $b.Root
                        if($target){ foreach($p in (Get-ChildItem -LiteralPath $bd -Directory | Select-Object -First 1)){ foreach($f in (Get-ChildItem -LiteralPath $p.FullName -File)){ Copy-Item $f.FullName (Join-Path $target.FullName $f.Name) -Force }; $n++ } }
                        else { WL '   Firefox has no profile yet - open Firefox once, then re-run this item' 'Warn' }
                    }
                }
                Note "$n profiles (browsers must be closed for this to stick)"
            }
        }
        'app_browserprofiles' {
            $base=P 'appdata\browsers\profiles'
            if(Test-Path -LiteralPath $base){ $n=0; foreach($b in (Get-BrowserMap)){ $s=Join-Path $base $b.Name; if(Test-Path -LiteralPath $s){ EnsureDir $b.Root; Robo $s $b.Root $false | Out-Null; $n++ } }; Manual "$n browsers restored - saved passwords/cookies will not decrypt on a new PC; sign in again" }
        }
        'app_putty'   { $f=P 'appdata\putty\putty.reg'; if(Test-Path -LiteralPath $f){ & reg import $f *>$null } }
        'user_custom' {
            $base=P 'userfolders\custom'; $mf=Join-Path $base 'map.json'
            if(Test-Path -LiteralPath $mf){ $n=0; foreach($m in @(Get-Content $mf -Raw | ConvertFrom-Json)){ $s=Join-Path $base $m.Rel; if(Test-Path -LiteralPath $s){ WL "   -> $($m.Original)"; Robo $s $m.Original $false | Out-Null; $n++ } }; Note "$n folders restored to original paths" }
        }
        'apps_ubundle'{ Manual 'apps.ubundle is in the backup - open it in UniGetUI to install' }
        'dev_wsl'     { Manual 'list only - see dev\wsl-distros.txt (use "WSL distros (full export)" to migrate data)' }
        'win_drives'  { $f=P 'windows\drives.csv'; if(Test-Path -LiteralPath $f){ $n=0; foreach($m in @(Import-Csv $f)){ if($m.LocalPath -and $m.RemotePath){ try{ New-SmbMapping -LocalPath $m.LocalPath -RemotePath $m.RemotePath -Persistent $true -ErrorAction Stop | Out-Null; $n++ }catch{ WL "   $($m.LocalPath) -> $($m.RemotePath) failed (share offline or needs credentials)" 'Warn' } } }; Manual "$n drives mapped - credentials must be entered again" } }
        'win_printers'{ Manual 'list only - see windows\printers.csv' }
        default {
            if($id -like 'user_*'){ $leaf=$Script:UserLeaf[$id]; $sp=P ("userfolders\{0}" -f $leaf); if(Test-Path -LiteralPath $sp){ $dst=UserFolderPath $id; if(-not $dst){ $dst=Join-Path $userHome $leaf }; Robo $sp $dst $false | Out-Null } }
        }
    }
}

function Start-RestoreRun {
    $src=$sync.RestoreSrc; $ids=@($sync.Ids); $pw=$sync.Password
    $manFile=Join-Path $src 'manifest.json'; if(-not (Test-Path -LiteralPath $manFile)){ WL 'manifest.json not found.' 'Error'; $sync.Result='error'; return }
    $man=Get-Content $manFile -Raw | ConvertFrom-Json
    try{ $sync.LogPath=Join-Path $src ("phoenix-restore-{0}-{1}.log" -f $env:COMPUTERNAME,(Get-Date -Format 'yyyyMMdd-HHmm')); Add-Content -LiteralPath $sync.LogPath -Value '' }catch{ $sync.LogPath=$null }
    WL ("Phoenix restore started {0} on {1} from backup of {2}" -f (Get-Date).ToString('g'),$env:COMPUTERNAME,$man.Machine)
    $Script:RSrc=$src; $Script:RVault=$null
    $needsRp = @($ids | Where-Object { $_ -like 'win_*' -or $_ -eq 'app_putty' }).Count -gt 0
    if($needsRp){ Prog 3 'Creating system restore point...'; try{ Checkpoint-Computer -Description 'Phoenix restore' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop; WL '   restore point created.' 'Ok' }catch{ WL '   restore point skipped (needs admin / may be throttled).' 'Warn' } }
    $secureIds=@($sync.SecureIds)
    $needsVault = $man.Vault -and (@($ids | Where-Object { $secureIds -contains $_ }).Count -gt 0)
    if($needsVault){
        if(-not $pw){ WL 'Vault password required for sensitive items.' 'Error'; $sync.Result='error'; return }
        Prog 6 'Decrypting vault...'
        try{ $Script:RVault=Open-Vault $src $pw; WL '   vault decrypted and verified.' 'Ok' }
        catch{ WL "Decryption failed - $($_.Exception.Message)" 'Error'; $sync.Result='error'; Emit 'Report' @{ Title='Restore failed'; Items=@(@{ Name='Vault'; Status='error'; Note='wrong password or corrupted vault' }) }; return }
    }
    $total=$ids.Count; $i=0; $report=@()
    foreach($id in $ids){
        if($sync.Cancel){ WL 'Cancelled.' 'Warn'; break }
        $i++; $nm=$sync.Meta[$id].Name; Prog ([int](6 + ($i-1)/$total*90)) "Restoring: $nm"; WL "-> $nm"
        $Script:CurNote=''; $Script:CurStatus='ok'
        try{ Invoke-ModuleRestore $id $src; $lvl=switch($Script:CurStatus){ 'manual'{'Warn'} 'skip'{'Warn'} default{'Ok'} }; WL ("   {0}{1}" -f $(if($Script:CurStatus -eq 'ok'){'done'}else{'needs attention'}),$(if($Script:CurNote){"  -  $($Script:CurNote)"}else{''})) $lvl; $report += @{ Name=$nm; Status=$Script:CurStatus; Note=$Script:CurNote } }
        catch{ WL ("   FAILED: {0}" -f $_.Exception.Message) 'Error'; $report += @{ Name=$nm; Status='error'; Note=$_.Exception.Message } }
    }
    if($Script:RVault -and (Test-Path -LiteralPath $Script:RVault)){ Remove-Item $Script:RVault -Recurse -Force -ErrorAction SilentlyContinue }
    Prog 100 'Restore complete'; WL 'Some changes need a sign-out/restart to appear.' 'Warn'; $sync.Result='restore'
    Emit 'Report' @{ Title=$(if($sync.Cancel){'Restore cancelled'}else{'Restore complete'}); Items=$report }
}

function Get-WslSize {
    $t=[long]0
    try{ foreach($k in (Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)){ $bp=(Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).BasePath; if($bp){ $bp=$bp -replace '^\\\\\?\\',''; $v=Join-Path $bp 'ext4.vhdx'; if(Test-Path -LiteralPath $v){ $t += (Get-Item -LiteralPath $v).Length } } } }catch{}
    $t
}
function Get-Estimate($id){
    $userHome=$env:USERPROFILE
    switch($id){
        'dev_ssh'        { FolderSize (Join-Path $userHome '.ssh') }
        'dev_wsl_export' { Get-WslSize }
        'win_fonts'      { FolderSize "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" }
        'app_appdata'    { $t=[long]0; foreach($a in (Get-AppDataMap)){ $s = if($sync.AppDataFull){ FolderSize $a.Src } else { SmartSize $a.Src }; $t+=$s; Emit 'AppSize' @{ Name=$a.Name; Bytes=$s } }; $t }
        'app_bookmarks'  { $t=[long]0; foreach($b in (Get-BrowserMap)){ if($b.Kind -eq 'chromium'){ foreach($p in (Get-ChromiumProfiles $b.Root)){ $f=Join-Path $p.FullName 'Bookmarks'; if(Test-Path -LiteralPath $f){ $t+=(Get-Item -LiteralPath $f).Length } } } else { foreach($p in (Get-FirefoxProfiles $b.Root)){ $f=Join-Path $p.FullName 'places.sqlite'; if(Test-Path -LiteralPath $f){ $t+=(Get-Item -LiteralPath $f).Length } } } }; $t }
        'app_browserprofiles' { $t=[long]0; foreach($b in (Get-BrowserMap)){ $t+=SmartSize $b.Root }; $t }
        'user_custom'    { $t=[long]0; foreach($f in @($sync.Custom)){ if($f){ $s=FolderSize $f; $t+=$s; Emit 'CustomSize' @{ Path=$f; Bytes=$s } } }; $t }
        default          { if($id -like 'user_*'){ FolderSize (UserFolderPath $id) } else { 51200 } }
    }
}

function Start-EstimateRun {
    $ids=@($sync.Ids); $i=0; $total=$ids.Count; $sum=0
    foreach($id in $ids){
        if($sync.Cancel){ break }
        $i++; Prog ([int]($i/$total*100)) "Sizing: $($sync.Meta[$id].Name)"
        $b=0
        try{ $b = [long](Get-Estimate $id) }catch{ $b=0 }
        $sum += $b; Emit 'Size' @{ Id=$id; Bytes=$b }
    }
    Emit 'EstimateDone' @{ Total=$sum }
}

# ---- Verify: re-hash every file against checksums.sha256 and check the vault MAC. ----
function Start-VerifyRun {
    $src=$sync.RestoreSrc; $pw=$sync.Password; $report=@()
    $cf=Join-Path $src 'checksums.sha256'
    if(-not (Test-Path -LiteralPath $cf)){ WL 'This backup has no checksums.sha256 (made without checksums).' 'Warn'; $report += @{ Name='Checksums'; Status='skip'; Note='not present in this backup' } }
    else {
        $lines=@(Get-Content -LiteralPath $cf -Encoding UTF8 | Where-Object { $_ -match '^([0-9A-Fa-f]{64}) \*(.+)$' })
        $ok=0; $bad=@(); $missing=@(); $i=0; $n=[math]::Max(1,$lines.Count)
        foreach($line in $lines){
            if($sync.Cancel){ break }
            $i++; if(($i % 100) -eq 0){ Prog ([int](90*$i/$n)) "Verifying $i / $($lines.Count) files" }
            if($line -match '^([0-9A-Fa-f]{64}) \*(.+)$'){ $h=$Matches[1]; $rel=$Matches[2]; $full=Join-Path $src $rel
                if(-not (Test-Path -LiteralPath $full)){ $missing+=$rel; continue }
                if((FileHash $full) -ieq $h){ $ok++ } else { $bad+=$rel }
            }
        }
        foreach($m in ($missing | Select-Object -First 30)){ WL "   missing: $m" 'Error' }
        foreach($b in ($bad | Select-Object -First 30)){ WL "   corrupted: $b" 'Error' }
        $st = if($bad.Count -eq 0 -and $missing.Count -eq 0){ 'ok' } else { 'error' }
        WL ("{0} files OK, {1} corrupted, {2} missing" -f $ok,$bad.Count,$missing.Count) $(if($st -eq 'ok'){'Ok'}else{'Error'})
        $report += @{ Name='File checksums'; Status=$st; Note=("{0} OK, {1} corrupted, {2} missing" -f $ok,$bad.Count,$missing.Count) }
    }
    $vf=Join-Path $src 'secure\vault.enc'
    if(Test-Path -LiteralPath $vf){
        Prog 95 'Checking vault...'
        if($pw){ try{ $r=Test-VaultMac $vf $pw; if($null -eq $r){ $report += @{ Name='Vault'; Status='skip'; Note='v1 vault (no integrity tag) - decrypts on restore only' } } elseif($r){ WL '   vault integrity OK (password correct).' 'Ok'; $report += @{ Name='Vault'; Status='ok'; Note='integrity verified, password correct' } } else { WL '   vault check FAILED - wrong password or corrupted.' 'Error'; $report += @{ Name='Vault'; Status='error'; Note='wrong password or corrupted' } } }catch{ $report += @{ Name='Vault'; Status='error'; Note=$_.Exception.Message } } }
        else { $report += @{ Name='Vault'; Status='skip'; Note='enter the password to verify the vault too' } }
    }
    $mf=Join-Path $src 'manifest.json'
    try{ $man=Get-Content $mf -Raw | ConvertFrom-Json; $miss=@(); foreach($m in $man.Modules){ if($m.Status -ne 'ok'){ continue }; foreach($p in @($m.Paths)){ if($p -and -not (Test-Path -LiteralPath (Join-Path $src $p)) -and -not ($man.SecurePaths -contains $p) -and -not $m.Secure){ $miss+="$($m.Name): $p" } } }; if($miss.Count){ foreach($x in $miss){ WL "   manifest path missing: $x" 'Error' }; $report += @{ Name='Manifest'; Status='error'; Note="$($miss.Count) module paths missing" } } else { $report += @{ Name='Manifest'; Status='ok'; Note="$(@($man.Modules).Count) modules listed" } } }catch{ $report += @{ Name='Manifest'; Status='error'; Note='unreadable' } }
    Prog 100 'Verify complete'; $sync.Result='verify'
    Emit 'Report' @{ Title='Verification result'; Items=$report }
}

# ---- Dry run: describe what restore would do on this PC without changing anything. ----
function Plan-Copy($name,$srcRel,$dst,$smart){
    $s=P $srcRel; if(-not (Test-Path -LiteralPath $s)){ return $null }
    $r=RoboPlan $s $dst $smart
    $exists = Test-Path -LiteralPath $dst
    $txt = if(-not $exists){ "create $dst  -  $($r.Total) files, $(Fmt-Bytes $r.Bytes)" } else { "$($r.Copy) new/changed files ($(Fmt-Bytes $r.Bytes)) into $dst, $($r.Skip) identical" }
    WL "   $txt"; return $txt
}
function Start-DryRunRun {
    $src=$sync.RestoreSrc; $ids=@($sync.Ids); $pw=$sync.Password; $report=@()
    $man=Get-Content (Join-Path $src 'manifest.json') -Raw | ConvertFrom-Json
    $Script:RSrc=$src; $Script:RVault=$null
    $secureIds=@($sync.SecureIds)
    if($man.Vault -and (@($ids | Where-Object { $secureIds -contains $_ }).Count -gt 0)){
        if($pw){ Prog 3 'Decrypting vault for inspection...'; try{ $Script:RVault=Open-Vault $src $pw; WL '   vault opened (temporary copy, deleted afterwards).' 'Ok' }catch{ WL "   vault could not be opened: $($_.Exception.Message)" 'Error'; $report += @{ Name='Vault'; Status='error'; Note='wrong password - sensitive items not inspected' } } }
        else { WL '   no password given - sensitive items are listed but not inspected.' 'Warn' }
    }
    $userHome=$env:USERPROFILE; $total=$ids.Count; $i=0
    $curWinget=$null
    foreach($id in $ids){
        if($sync.Cancel){ break }
        $i++; $nm=$sync.Meta[$id].Name; Prog ([int](5 + ($i-1)/$total*93)) "Planning: $nm"; WL "-> $nm"
        $st='ok'; $note=''
        try{
            switch($id){
                'apps_winget' {
                    $f=P 'apps\winget-packages.json'
                    if(-not (CmdExists 'winget')){ $st='manual'; $note='winget missing on this PC' }
                    elseif(Test-Path -LiteralPath $f){
                        $pk=@((Get-Content $f -Raw | ConvertFrom-Json).Sources | ForEach-Object { $_.Packages } | ForEach-Object { $_.PackageIdentifier })
                        if($null -eq $curWinget){ $tmp=Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')+'.json'); & winget export -o $tmp --accept-source-agreements *>$null; $curWinget=@{}; try{ foreach($s in (Get-Content $tmp -Raw | ConvertFrom-Json).Sources){ foreach($p in $s.Packages){ $curWinget[$p.PackageIdentifier]=$true } } }catch{}; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
                        $new=@($pk | Where-Object { -not $curWinget[$_] })
                        $note="{0} to install, {1} already present" -f $new.Count,($pk.Count-$new.Count)
                        foreach($p in ($new | Select-Object -First 25)){ WL "   install: $p" }; if($new.Count -gt 25){ WL "   ... and $($new.Count-25) more" }
                    }
                }
                'apps_inventory' { $f=P 'apps\installed-programs.csv'; if(Test-Path -LiteralPath $f){ $old=@(Import-Csv $f); $cur=@{}; foreach($p in (Get-InstalledPrograms)){ $cur[$p.Name.ToLower()]=$true }; $missing=@($old | Where-Object { -not $cur[$_.Name.ToLower()] }); $st='manual'; $note="$($missing.Count) of $($old.Count) programs not installed here (checklist only)"; foreach($m in ($missing | Select-Object -First 25)){ WL "   not installed: $($m.Name)" } } }
                'dev_vscode' { $parts=@(); foreach($pair in @(@('code','vscode'),@('code-insiders','vscode-insiders'),@('cursor','cursor'))){ $f=P ("dev\{0}-extensions.txt" -f $pair[1]); if(-not (Test-Path -LiteralPath $f)){ continue }; $want=@(Get-Content $f | Where-Object { $_.Trim() }); if(CmdExists $pair[0]){ $have=@(& $pair[0] --list-extensions 2>$null); $new=@($want | Where-Object { $have -notcontains $_ }); $parts+="{0}: {1} to install, {2} present" -f $pair[0],$new.Count,($want.Count-$new.Count) } else { $parts+="{0}: not installed ({1} extensions waiting)" -f $pair[0],$want.Count; $st='manual' } }; $note=$parts -join '; ' }
                'dev_node' { $f=P 'dev\npm-globals.json'; if(Test-Path -LiteralPath $f){ $j=Get-Content $f -Raw | ConvertFrom-Json; $n=@($j.dependencies.PSObject.Properties.Name | Where-Object { $_ -ne 'npm' }).Count; if(CmdExists 'npm'){ $note="$n global packages to install" } else { $st='manual'; $note="npm missing - $n packages waiting" } } }
                'dev_python' { $d=P 'dev\python'; if(Test-Path -LiteralPath $d){ $files=@(Get-ChildItem -LiteralPath $d -Filter 'pip*.txt'); $have=@(); if(CmdExists 'py'){ $have=@(& py -0 2>$null | ForEach-Object { if($_ -match '(\d+\.\d+)'){ $Matches[1] } }) }; $parts=@(); foreach($f in $files){ $v=if($f.BaseName -match '(\d+\.\d+)'){$Matches[1]}else{'?'}; $c=@(Get-Content $f.FullName | Where-Object { $_.Trim() }).Count; if($have -contains $v -or (CmdExists 'python')){ $parts+="Python $v`: $c packages" } else { $parts+="Python $v`: NOT installed ($c packages waiting)"; $st='manual' } }; $note=$parts -join '; ' } }
                'dev_rust' { $f=P 'dev\cargo-crates.txt'; if(Test-Path -LiteralPath $f){ $n=@(Get-Content $f | Where-Object { $_ -match '^\S+\s+v' }).Count; if(CmdExists 'cargo'){ $note="$n crates to compile/install" } else { $st='manual'; $note="cargo missing - $n crates waiting" } } }
                'dev_dotnet' { $f=P 'dev\dotnet-tools.txt'; if(Test-Path -LiteralPath $f){ $n=@(Get-Content $f | Select-Object -Skip 2 | Where-Object { $_.Trim() }).Count; if(CmdExists 'dotnet'){ $note="$n tools to install" } else { $st='manual'; $note="dotnet missing - $n tools waiting" } } }
                'dev_git' { $g=P 'dev\git'; $parts=@(); if(Test-Path -LiteralPath $g){ foreach($f in (Get-ChildItem -LiteralPath $g -File)){ $dst=Join-Path $userHome $f.Name; $parts += if(-not (Test-Path -LiteralPath $dst)){ "$($f.Name): new" } elseif(SameFile $f.FullName $dst){ "$($f.Name): identical" } else { "$($f.Name): will overwrite" } } }; if(Test-Path -LiteralPath (P 'dev\git-credentials\.git-credentials')){ $parts+='credentials: restore' } elseif($secureIds -contains 'dev_git' -and -not $Script:RVault){ $parts+='credentials: in vault (not inspected)' }; $note=$parts -join ', ' }
                'dev_ssh' { if($Script:RVault -or -not $man.Vault){ $note=Plan-Copy $nm 'dev\ssh' (Join-Path $userHome '.ssh') $false; if(-not $note){ $note='nothing in backup' } } else { $st='skip'; $note='in vault - password needed to inspect' } }
                'dev_ps' { $p=P 'dev\powershell\profile.ps1'; $parts=@(); if(Test-Path -LiteralPath $p){ $parts += if(-not (Test-Path -LiteralPath $PROFILE)){ 'profile: new' } elseif(SameFile $p $PROFILE){ 'profile: identical' } else { 'profile: will overwrite' } }; $m=P 'dev\powershell\modules.json'; if(Test-Path -LiteralPath $m){ $mods=@(Get-Content $m -Raw | ConvertFrom-Json); $have=@{}; foreach($x in (Get-Module -ListAvailable -ErrorAction SilentlyContinue)){ $have[$x.Name]=$true }; $new=@($mods | Where-Object { $_.Name -and -not $have[$_.Name] }); $parts+="$($new.Count) modules to install, $($mods.Count-$new.Count) present" }; $note=$parts -join '; ' }
                'dev_env' { $f=P 'dev\env-user.json'; if(Test-Path -LiteralPath $f){ $j=Get-Content $f -Raw | ConvertFrom-Json; $new=0; $chg=0; $same=0; $pathAdd=0; foreach($k in $j.PSObject.Properties.Name){ $cur=[Environment]::GetEnvironmentVariable($k,'User'); if($k -eq 'Path'){ $curP=@($cur -split ';' | Where-Object { $_ }); $pathAdd=@($j.$k -split ';' | Where-Object { $_ -and ($curP -notcontains $_) }).Count } elseif($null -eq $cur){ $new++ } elseif($cur -ne $j.$k){ $chg++; WL "   change $k" } else { $same++ } }; $note="$new new, $chg changed, $same identical; $pathAdd PATH entries to append" } }
                'dev_wsl_export' { $d=P 'dev\wsl'; if(Test-Path -LiteralPath $d){ $have=@(Get-WslDistros); $tars=@(Get-ChildItem -LiteralPath $d -Filter *.tar); $new=@($tars | Where-Object { $have -notcontains $_.BaseName }); $note="$($new.Count) distros to import ($(Fmt-Bytes (($new | Measure-Object Length -Sum).Sum))), $($tars.Count-$new.Count) already exist"; if(-not (CmdExists 'wsl')){ $st='manual'; $note+=' - WSL not enabled' } } }
                'win_wifi' { $d=P 'windows\wifi'; if(Test-Path -LiteralPath $d){ $n=@(Get-ChildItem -LiteralPath $d -Filter *.xml).Count; $note="$n profiles to import"; if(-not $sync.IsAdmin){ $st='manual'; $note+=' (needs admin)' } } elseif($secureIds -contains 'win_wifi'){ $st='skip'; $note='in vault - password needed to inspect' } }
                'win_power' { $d=P 'windows\power'; if(Test-Path -LiteralPath $d){ $note="$(@(Get-ChildItem -LiteralPath $d -Filter *.pow).Count) plans to import" } }
                'win_netadapter' { $f=P 'windows\netadapters.json'; if(Test-Path -LiteralPath $f){ $plan=Plan-NetAdapter $f; foreach($c in $plan.Changes){ WL "   $($c.Nic): $($c.DisplayName) $($c.CurrentDisplay) -> $($c.DisplayValue)" }; $note="$($plan.Changes.Count) settings to change on $($plan.Matched) adapters, $($plan.Same) already match"; if($plan.Unmatched.Count -gt 0){ $note+="; no match for $($plan.Unmatched -join ', ')" }; if(-not $sync.IsAdmin){ $st='manual'; $note+=' (needs admin)' } } }
                'win_netip' { $f=P 'windows\netip.json'; if(Test-Path -LiteralPath $f){ $plan=Plan-NetIP $f; foreach($c in $plan.Changes){ WL "   $($c.Text)" }; $note="$($plan.Changes.Count) changes on $($plan.Matched) adapters, $($plan.Same) already match, $($plan.Dhcp) DHCP (left alone)"; if($plan.Unmatched.Count -gt 0){ $note+="; no match for $($plan.Unmatched -join ', ')" }; if(-not $sync.IsAdmin -and $plan.Changes.Count -gt 0){ $st='manual'; $note+=' (needs admin)' } } }
                'win_hosts' { $f=P 'windows\hosts'; if(Test-Path -LiteralPath $f){ $cur="$env:WINDIR\System32\drivers\etc\hosts"; $note = if(SameFile $f $cur){ 'identical to current hosts file' } else { 'will overwrite hosts file' }; if(-not $sync.IsAdmin){ $st='manual'; $note+=' (needs admin)' } } }
                'win_tasks' { $d=P 'windows\tasks'; if(Test-Path -LiteralPath $d){ $note="$(@(Get-ChildItem -LiteralPath $d -Filter *.xml).Count) tasks to register"; if(-not $sync.IsAdmin){ $st='manual'; $note+=' (some need admin)' } } }
                'win_explorer' { $note='will merge Explorer\Advanced registry values (sign out to apply)' }
                'win_terminal' { $f=P 'windows\terminal-settings.json'; if(Test-Path -LiteralPath $f){ $t=@("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState","$env:LOCALAPPDATA\Microsoft\Windows Terminal") | Where-Object { Test-Path -LiteralPath $_ }; $note = if($t){ "will write settings.json to $($t.Count) location(s)" } else { 'Windows Terminal not found - settings will be staged for a later install' } } }
                'win_defaultapps' { $note='will import default app associations'; if(-not $sync.IsAdmin){ $st='manual'; $note+=' (needs admin)' } }
                'win_fonts' { $d=P 'windows\fonts'; if(Test-Path -LiteralPath $d){ $n=@(Get-ChildItem -LiteralPath $d -File).Count; $note="$n font files to copy + register" } }
                'app_appdata' { $parts=@(); foreach($app in @($sync.AppDataMap)){ $s=P ("appdata\{0}" -f $app.Name); if(Test-Path -LiteralPath $s){ $r=RoboPlan $s $app.Src $false; $parts+="{0}: {1} files ({2})" -f $app.Name,$r.Copy,(Fmt-Bytes $r.Bytes); WL "   $($app.Name) -> $($app.Src): $($r.Copy) files, $($r.Skip) identical" } }; $note=$parts -join '; ' }
                'app_bookmarks' { $base=P 'appdata\browsers\bookmarks'; if(Test-Path -LiteralPath $base){ $parts=@(); foreach($b in (Get-BrowserMap)){ $bd=Join-Path $base $b.Name; if(-not (Test-Path -LiteralPath $bd)){ continue }; $n=@(Get-ChildItem -LiteralPath $bd -Directory).Count; $inst=Test-Path -LiteralPath $b.Root; $parts+="{0}: {1} profile(s){2}" -f $b.Name,$n,$(if($inst){''}else{' - browser not installed yet'}); if(-not $inst){ $st='manual' } }; $note=$parts -join '; ' } }
                'app_browserprofiles' { if($Script:RVault -or -not $man.Vault){ $base=P 'appdata\browsers\profiles'; if(Test-Path -LiteralPath $base){ $parts=@(); foreach($b in (Get-BrowserMap)){ $s=Join-Path $base $b.Name; if(Test-Path -LiteralPath $s){ $r=RoboPlan $s $b.Root $false; $parts+="{0}: {1} files ({2})" -f $b.Name,$r.Copy,(Fmt-Bytes $r.Bytes) } }; $note=($parts -join '; ')+' - passwords/cookies will not carry over' } } else { $st='skip'; $note='in vault - password needed to inspect' } }
                'app_putty' { if($Script:RVault -or -not $man.Vault){ $note = if(Test-Path -LiteralPath (P 'appdata\putty\putty.reg')){ 'will merge PuTTY sessions into registry' } else { 'nothing in backup' } } else { $st='skip'; $note='in vault - password needed to inspect' } }
                'user_custom' { $mf=P 'userfolders\custom\map.json'; if(Test-Path -LiteralPath $mf){ $parts=@(); foreach($m in @(Get-Content $mf -Raw | ConvertFrom-Json)){ $r=RoboPlan (Join-Path (P 'userfolders\custom') $m.Rel) $m.Original $false; WL "   $($m.Original): $($r.Copy) files ($(Fmt-Bytes $r.Bytes)), $($r.Skip) identical"; $parts+="{0} files" -f $r.Copy }; $note="$($parts.Count) folders, $(($parts | ForEach-Object { [int]($_ -split ' ')[0] } | Measure-Object -Sum).Sum) files to copy" } }
                { $_ -in 'apps_ubundle','dev_wsl','win_printers','win_drives' } { $st='manual'; $note='informational - manual step on the new PC' }
                default { if($id -like 'user_*'){ $leaf=$Script:UserLeaf[$id]; $dst=UserFolderPath $id; $note=Plan-Copy $nm ("userfolders\{0}" -f $leaf) $dst $false; if(-not $note){ $note='nothing in backup' } } }
            }
        }catch{ $st='error'; $note=$_.Exception.Message }
        $report += @{ Name=$nm; Status=$st; Note=$note }
        if($note){ WL "   $note" $(switch($st){ 'ok'{'Ok'} 'error'{'Error'} default{'Warn'} }) }
    }
    if($Script:RVault -and (Test-Path -LiteralPath $Script:RVault)){ Remove-Item $Script:RVault -Recurse -Force -ErrorAction SilentlyContinue }
    Prog 100 'Dry run complete - nothing was changed'; $sync.Result='dryrun'
    Emit 'Report' @{ Title='Dry run - what restore would do'; Items=$report }
}

# ---- Compare: what changed between two backups (module status/size, files via checksums, package/extension/env lists). ----
$Script:CompareListFiles=@('apps\winget-packages.json','apps\installed-programs.csv','dev\vscode-extensions.txt','dev\vscode-insiders-extensions.txt','dev\cursor-extensions.txt','dev\npm-globals.json','dev\cargo-crates.txt','dev\dotnet-tools.txt','dev\env-user.json','dev\powershell\modules.json')
# Keeps just the small list files + manifest + checksums so a mirror update can still be diffed against what it overwrote.
function Snapshot-BackupMeta($root){
    $snap=Join-Path $env:TEMP ('phx_prev_'+[Guid]::NewGuid().ToString('N'))
    foreach($rel in (@('manifest.json','checksums.sha256') + $Script:CompareListFiles)){ $s=Join-Path $root $rel; if(Test-Path -LiteralPath $s){ $t=Join-Path $snap $rel; EnsureDir (Split-Path $t -Parent); Copy-Item -LiteralPath $s -Destination $t -Force } }
    $pd=Join-Path $root 'dev\python'; if(Test-Path -LiteralPath $pd){ $t=Join-Path $snap 'dev\python'; EnsureDir $t; Get-ChildItem -LiteralPath $pd -Filter 'pip*.txt' | Copy-Item -Destination $t -Force }
    $snap
}
# rel -> sha256 when checksums exist, else rel -> "L<length>" so presence/size can still be diffed. $null when a meta-only snapshot has no checksums.
function Read-FileMap($root,$metaOnly){
    $map=@{}; $cf=Join-Path $root 'checksums.sha256'
    if(Test-Path -LiteralPath $cf){ foreach($line in (Get-Content -LiteralPath $cf -Encoding UTF8)){ if($line -match '^([0-9A-Fa-f]{64}) \*(.+)$'){ $map[$Matches[2]]=$Matches[1].ToLower() } }; return @{ Map=$map; Hashed=$true } }
    if($metaOnly){ return $null }
    foreach($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)){ if($f.DirectoryName -eq $root -and ($Script:MetaFiles -contains $f.Name -or $f.Name -like 'phoenix-restore-*.log')){ continue }; $map[(RelOf $root $f.FullName)]="L$($f.Length)" }
    @{ Map=$map; Hashed=$false }
}
function Read-ListSets($root){
    $sets=[ordered]@{}
    $f=Join-Path $root 'apps\winget-packages.json'; if(Test-Path -LiteralPath $f){ try{ $sets['Apps (winget)']=@((Get-Content $f -Raw | ConvertFrom-Json).Sources | ForEach-Object { $_.Packages } | ForEach-Object { $_.PackageIdentifier }) }catch{} }
    $f=Join-Path $root 'apps\installed-programs.csv'; if(Test-Path -LiteralPath $f){ try{ $sets['Installed programs']=@(Import-Csv $f | ForEach-Object { "$($_.Name) $($_.Version)".Trim() }) }catch{} }
    foreach($pair in @(@('vscode','VS Code extensions'),@('vscode-insiders','VS Code Insiders extensions'),@('cursor','Cursor extensions'))){ $f=Join-Path $root "dev\$($pair[0])-extensions.txt"; if(Test-Path -LiteralPath $f){ $sets[$pair[1]]=@(Get-Content $f | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } }
    $f=Join-Path $root 'dev\npm-globals.json'; if(Test-Path -LiteralPath $f){ try{ $j=Get-Content $f -Raw | ConvertFrom-Json; $sets['npm globals']=@($j.dependencies.PSObject.Properties | ForEach-Object { "$($_.Name)@$($_.Value.version)" }) }catch{} }
    $pd=Join-Path $root 'dev\python'; if(Test-Path -LiteralPath $pd){ foreach($pf in (Get-ChildItem -LiteralPath $pd -Filter 'pip*.txt')){ $sets["pip ($($pf.BaseName))"]=@(Get-Content $pf.FullName | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } }
    $f=Join-Path $root 'dev\cargo-crates.txt'; if(Test-Path -LiteralPath $f){ $sets['cargo crates']=@(Get-Content $f | ForEach-Object { if($_ -match '^(\S+\s+v\S+)'){ $Matches[1] } }) }
    $f=Join-Path $root 'dev\dotnet-tools.txt'; if(Test-Path -LiteralPath $f){ $sets['dotnet tools']=@(Get-Content $f | Select-Object -Skip 2 | ForEach-Object { (($_ -split '\s+') | Select-Object -First 2) -join ' ' } | Where-Object { $_.Trim() }) }
    $f=Join-Path $root 'dev\powershell\modules.json'; if(Test-Path -LiteralPath $f){ try{ $sets['PowerShell modules']=@(Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { "$($_.Name) $($_.Version)" }) }catch{} }
    $f=Join-Path $root 'dev\env-user.json'
    if(Test-Path -LiteralPath $f){ try{ $j=Get-Content $f -Raw | ConvertFrom-Json; $vars=@(); $path=@(); foreach($p in $j.PSObject.Properties){ if($p.Name -eq 'Path'){ $path=@([string]$p.Value -split ';' | Where-Object { $_ }) } else { $vars+="$($p.Name)=$($p.Value)" } }; $sets['Environment variables']=$vars; $sets['PATH entries']=$path }catch{} }
    $sets
}
function Diff-Sets($a,$b){ $ha=@{}; foreach($x in $a){ $ha[$x]=$true }; $hb=@{}; foreach($x in $b){ $hb[$x]=$true }; @{ Added=@($b | Where-Object { -not $ha[$_] }); Removed=@($a | Where-Object { -not $hb[$_] }) } }
function Group-Of($rel,$modPaths){ $best=$null; foreach($p in $modPaths.Keys){ if(($rel -eq $p -or $rel.StartsWith($p+'\')) -and ($null -eq $best -or $p.Length -gt $best.Length)){ $best=$p } }; if($best){ $modPaths[$best] } else { '(other)' } }

function Compare-Backups($oldRoot,$newRoot,$oldLabel,$newLabel,$metaOnly,$showProgress){
    $report=@(); $txt=New-Object System.Text.StringBuilder
    $null=$txt.AppendLine("Phoenix compare:  $oldLabel  ->  $newLabel"); $null=$txt.AppendLine("Generated $((Get-Date).ToString('g')) on $env:COMPUTERNAME"); $null=$txt.AppendLine()
    $mo=Get-Content (Join-Path $oldRoot 'manifest.json') -Raw | ConvertFrom-Json
    $mn=Get-Content (Join-Path $newRoot 'manifest.json') -Raw | ConvertFrom-Json

    if($showProgress){ Prog 10 'Comparing modules...' }
    $null=$txt.AppendLine('== Modules =='); $changedMods=0
    $oldMods=@{}; foreach($m in @($mo.Modules)){ $oldMods[$m.Id]=$m }; $newMods=@{}; foreach($m in @($mn.Modules)){ $newMods[$m.Id]=$m }
    $modPaths=@{}; foreach($m in (@($mn.Modules)+@($mo.Modules))){ foreach($p in (@($m.Paths)+@($m.SecurePaths))){ if($p -and -not $modPaths.ContainsKey($p)){ $modPaths[$p]=$m.Name } } }
    $allIds=@(@($oldMods.Keys)+@($newMods.Keys) | Select-Object -Unique)
    foreach($id in $allIds){
        $o=$oldMods[$id]; $n=$newMods[$id]; $name= if($n){ $n.Name } else { $o.Name }
        if(-not $o){ $null=$txt.AppendLine("  + $name  (new: $($n.Status), $(Fmt-Bytes $n.Size))"); $changedMods++; continue }
        if(-not $n){ $null=$txt.AppendLine("  - $name  (no longer backed up)"); $changedMods++; continue }
        $delta=[long]$n.Size-[long]$o.Size
        if($o.Status -ne $n.Status -or $delta -ne 0 -or [string]$o.Note -ne [string]$n.Note){
            $changedMods++
            $parts=@(); if($o.Status -ne $n.Status){ $parts+="$($o.Status) -> $($n.Status)" }; if($delta -ne 0){ $parts+=("size {0}{1}" -f $(if($delta -gt 0){'+'}else{'-'}),(Fmt-Bytes ([math]::Abs($delta)))) }; if([string]$o.Note -ne [string]$n.Note){ $parts+="'$($o.Note)' -> '$($n.Note)'" }
            $null=$txt.AppendLine("  ~ $name  $($parts -join '  ')")
        }
    }
    if($changedMods -eq 0){ $null=$txt.AppendLine('  no changes') }
    $report += @{ Name='Modules'; Status=$(if($changedMods){'changed'}else{'ok'}); Note="$changedMods of $($allIds.Count) modules changed (status, size or note)" }

    if($showProgress){ Prog 30 'Comparing files...' }
    $null=$txt.AppendLine(); $null=$txt.AppendLine('== Files ==')
    $fo=Read-FileMap $oldRoot $metaOnly; $fn=Read-FileMap $newRoot $false
    $added=@(); $removed=@(); $changed=@(); $same=0
    if($null -eq $fo){ $null=$txt.AppendLine('  previous run had no checksums - file-level diff not available'); $report += @{ Name='Files'; Status='skip'; Note='previous backup had no checksums' } }
    else {
        $contentCmp = ($fo.Hashed -eq $fn.Hashed)
        foreach($k in $fn.Map.Keys){ if($k -like 'secure\*'){ continue }; if(-not $fo.Map.ContainsKey($k)){ $added+=$k } elseif($contentCmp -and $fo.Map[$k] -ne $fn.Map[$k]){ $changed+=$k } else { $same++ } }
        foreach($k in $fo.Map.Keys){ if($k -like 'secure\*'){ continue }; if(-not $fn.Map.ContainsKey($k)){ $removed+=$k } }
        $groups=[ordered]@{}
        foreach($pair in @(@('+',$added),@('-',$removed),@('~',$changed))){ foreach($k in $pair[1]){ $g=Group-Of $k $modPaths; if(-not $groups.Contains($g)){ $groups[$g]=@{ '+'=@(); '-'=@(); '~'=@() } }; $groups[$g][$pair[0]] += $k } }
        foreach($g in $groups.Keys){
            $gg=$groups[$g]
            $null=$txt.AppendLine(("  {0}: +{1} -{2} ~{3}" -f $g,$gg['+'].Count,$gg['-'].Count,$gg['~'].Count))
            foreach($sym in '+','-','~'){ foreach($k in ($gg[$sym] | Select-Object -First 40)){ $null=$txt.AppendLine("     $sym $k") }; if($gg[$sym].Count -gt 40){ $null=$txt.AppendLine("     $sym ... and $($gg[$sym].Count-40) more") } }
            $report += @{ Name=$g; Status='changed'; Note=("+{0} added, -{1} removed, {2} changed" -f $gg['+'].Count,$gg['-'].Count,$gg['~'].Count) }
            WL ("   {0}: +{1} -{2} ~{3} files" -f $g,$gg['+'].Count,$gg['-'].Count,$gg['~'].Count)
        }
        if($groups.Count -eq 0){ $null=$txt.AppendLine('  no file changes') }
        $how = if(-not $contentCmp){ ' (presence only - one side has no checksums)' } elseif(-not $fn.Hashed){ ' (by size - no checksums)' } else { '' }
        if(Test-Path -LiteralPath (Join-Path $newRoot 'secure\vault.enc')){ $null=$txt.AppendLine('  encrypted vault not compared') }
        $report += @{ Name='Files'; Status=$(if($added.Count+$removed.Count+$changed.Count){'changed'}else{'ok'}); Note=("+{0} added, -{1} removed, {2} changed, {3} unchanged{4}" -f $added.Count,$removed.Count,$changed.Count,$same,$how) }
    }

    if($showProgress){ Prog 70 'Comparing package & extension lists...' }
    $null=$txt.AppendLine(); $null=$txt.AppendLine('== Lists ==')
    $lo=Read-ListSets $oldRoot; $ln=Read-ListSets $newRoot; $listChanges=0
    foreach($name in @(@($lo.Keys)+@($ln.Keys) | Select-Object -Unique)){
        if(-not $lo.Contains($name) -or -not $ln.Contains($name)){ $side= if($ln.Contains($name)){ 'new' } else { 'old' }; $null=$txt.AppendLine("  $name : only in $side backup"); $report += @{ Name=$name; Status='skip'; Note="only in the $side backup" }; continue }
        $d=Diff-Sets $lo[$name] $ln[$name]
        if($d.Added.Count -eq 0 -and $d.Removed.Count -eq 0){ $report += @{ Name=$name; Status='ok'; Note="unchanged ($(@($ln[$name]).Count) entries)" }; continue }
        $listChanges += $d.Added.Count + $d.Removed.Count
        $null=$txt.AppendLine("  $name : +$($d.Added.Count) -$($d.Removed.Count)"); foreach($x in $d.Added){ $null=$txt.AppendLine("     + $x") }; foreach($x in $d.Removed){ $null=$txt.AppendLine("     - $x") }
        foreach($x in ($d.Added | Select-Object -First 10)){ WL "   $name  + $x" }; foreach($x in ($d.Removed | Select-Object -First 10)){ WL "   $name  - $x" }
        if($d.Added.Count + $d.Removed.Count -gt 20){ WL "   $name  ... see compare.txt for the full list" }
        $report += @{ Name=$name; Status='changed'; Note="+$($d.Added.Count) added, -$($d.Removed.Count) removed" }
    }
    if($lo.Count -eq 0 -and $ln.Count -eq 0){ $null=$txt.AppendLine('  no list files in either backup') }

    $summary = "{0} modules, +{1}/-{2}/~{3} files, {4} list entries changed" -f $changedMods,$added.Count,$removed.Count,$changed.Count,$listChanges
    @{ Report=$report; Text=$txt.ToString(); Summary=$summary; Any=(($changedMods + $added.Count + $removed.Count + $changed.Count + $listChanges) -gt 0) }
}
function Write-CompareFile($root,$text){ try{ [IO.File]::WriteAllText((Join-Path $root 'compare.txt'),$text,(New-Object System.Text.UTF8Encoding($false))); $true }catch{ WL "   could not write compare.txt: $($_.Exception.Message)" 'Warn'; $false } }

function Start-CompareRun {
    $a=$sync.CompareA; $b=$sync.CompareB
    $ma=Get-Content (Join-Path $a 'manifest.json') -Raw | ConvertFrom-Json; $mb=Get-Content (Join-Path $b 'manifest.json') -Raw | ConvertFrom-Json
    if([datetime]$ma.Created -gt [datetime]$mb.Created){ $t=$a; $a=$b; $b=$t }
    $la=Split-Path $a -Leaf; $lb=Split-Path $b -Leaf
    WL "Older: $a"; WL "Newer: $b"
    $r=Compare-Backups $a $b $la $lb $false $true
    if(Write-CompareFile $b $r.Text){ WL "   details written to $(Join-Path $b 'compare.txt')" 'Ok' }
    WL "   $($r.Summary)" $(if($r.Any){'Warn'}else{'Ok'})
    $sync.OutputPath=$b; $sync.Result='compare'
    Prog 100 'Compare complete'
    Emit 'Report' @{ Title="Changes: $la  ->  $lb"; Items=$r.Report }
}

try{
    switch($sync.Op){
        'Backup'   { Start-BackupRun }
        'Restore'  { Start-RestoreRun }
        'Estimate' { Start-EstimateRun }
        'Verify'   { Start-VerifyRun }
        'DryRun'   { Start-DryRunRun }
        'Compare'  { Start-CompareRun }
    }
}catch{ WL $_.Exception.Message 'Error' }
finally{ Emit 'Done' @{} }
'@
#endregion

#region ------------------------------------------------------------ Headless mode (scheduled / CLI backups)
if($Headless){
    if(-not $Dest){ Write-Error 'Headless mode needs -Dest <folder>.'; exit 2 }
    if(-not (Test-Path -LiteralPath $Dest)){ New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    # -File passes "a,b,c" as one string; accept both forms.
    if($Items){ $Items = @($Items | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $ids = if($Items){ @($Items | Where-Object { $Script:ModuleById.ContainsKey($_) }) } elseif($Preset -eq 'Everything'){ @($Script:Modules | ForEach-Object { $_.Id }) } else { @($Script:Modules | Where-Object { $_.Presets -contains $Preset } | ForEach-Object { $_.Id }) }
    if($ids.Count -eq 0){ Write-Error 'Nothing selected (check -Preset / -Items).'; exit 2 }
    $sync = [hashtable]::Synchronized(@{})
    $sync.Events = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $sync.Console=$true; $sync.Cancel=$false; $sync.Op='Backup'; $sync.Ids=$ids; $sync.Dest=$Dest
    $sync.Meta=@{}; foreach($m in $Script:Modules){ $sync.Meta[$m.Id]=@{ Name=$m.Name; Cat=$m.Cat; Sensitive=[bool]$m.Sensitive } }
    $sync.AppDataMap=$Script:AppDataMap; $sync.AppDataSel=$null; $sync.AppDataFull=$false
    $sync.Custom=@($Script:Settings.CustomFolders); $sync.UpdateExisting=[bool]$Update; $sync.NoChecksums=[bool]$NoChecksums
    $sync.Encrypt=[bool]$Encrypt; $sync.Password=$env:PHOENIX_VAULT_PASSWORD
    if($Encrypt -and -not $sync.Password){ Write-Error 'Set PHOENIX_VAULT_PASSWORD when using -Encrypt.'; exit 2 }
    $sync.IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Invoke-Expression $Script:WorkerText
    $hadError = $false
    while($sync.Events.Count -gt 0){ $e=$sync.Events.Dequeue(); if($e.Type -eq 'Log' -and $e.Data.Level -eq 'Error'){ $hadError=$true } }
    exit $(if($hadError){ 1 } else { 0 })
}
#endregion

#region ------------------------------------------------------------ XAML UI
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" Width="1080" Height="720"
        FontFamily="Segoe UI" Title="Phoenix">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg0" Color="#0B0F17"/>
    <SolidColorBrush x:Key="Bg1" Color="#111827"/>
    <SolidColorBrush x:Key="Bg2" Color="#151E2E"/>
    <SolidColorBrush x:Key="Bg3" Color="#1B2536"/>
    <SolidColorBrush x:Key="Stroke" Color="#26324A"/>
    <SolidColorBrush x:Key="Txt" Color="#E7EEF8"/>
    <SolidColorBrush x:Key="Muted" Color="#8494AB"/>
    <SolidColorBrush x:Key="Accent" Color="#F97316"/>
    <SolidColorBrush x:Key="AccentDim" Color="#EA6A0E"/>
    <SolidColorBrush x:Key="Good" Color="#22C55E"/>
    <SolidColorBrush x:Key="Warn" Color="#F59E0B"/>
    <SolidColorBrush x:Key="Bad" Color="#EF4444"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Txt}"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>

    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="TextOptions.TextFormattingMode" Value="Ideal"/>
    </Style>

    <Style x:Key="Nav" TargetType="Button">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="9" Background="Transparent" Padding="12,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Bg3}"/></Trigger>
              <Trigger Property="Tag" Value="active">
                <Setter TargetName="b" Property="Background" Value="{StaticResource Bg3}"/>
                <Setter Property="Foreground" Value="{StaticResource Txt}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="10" Padding="18,0">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#FB8C3E" Offset="0"/><GradientStop Color="#F97316" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.92"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Height" Value="38"/>
      <Setter Property="Foreground" Value="{StaticResource Txt}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="9" Padding="14,0" Background="{StaticResource Bg3}" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Width" Value="44"/><Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="11"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="7" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Bg3}"/><Setter Property="Foreground" Value="{StaticResource Txt}"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Txt}"/>
      <Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="box" Width="19" Height="19" CornerRadius="6" Background="{StaticResource Bg0}" BorderBrush="{StaticResource Stroke}" BorderThickness="1.5" VerticalAlignment="Center">
                <TextBlock x:Name="chk" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center" Margin="10,0,0,0"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="chk" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="38"/><Setter Property="Foreground" Value="{StaticResource Txt}"/>
      <Setter Property="Background" Value="{StaticResource Bg3}"/><Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource Bg0}" CornerRadius="14" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/></Grid.RowDefinitions>

      <!-- Title bar -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
          <Border Width="26" Height="26" CornerRadius="8">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FB8C3E" Offset="0"/><GradientStop Color="#F97316" Offset="1"/></LinearGradientBrush></Border.Background>
            <TextBlock Style="{StaticResource Icon}" Text="&#xEB05;" FontSize="14" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Phoenix" FontSize="15" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
          <TextBlock Text="Windows Migration Kit" Foreground="{StaticResource Muted}" FontSize="12" Margin="10,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
          <Border x:Name="AdminBadge" CornerRadius="7" Background="{StaticResource Bg3}" Padding="10,4" Margin="0,0,8,0" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xEA18;" FontSize="11" Foreground="{StaticResource Good}"/><TextBlock Text="Administrator" FontSize="11" Foreground="{StaticResource Muted}" Margin="6,0,0,0"/></StackPanel>
          </Border>
          <Button x:Name="BtnElevate" Style="{StaticResource Ghost}" Height="30" Margin="0,0,8,0" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xEA18;" FontSize="11"/><TextBlock Text="Run as admin" FontSize="12" Margin="6,0,0,0"/></StackPanel>
          </Button>
          <Button x:Name="BtnMin" Style="{StaticResource WinBtn}" Content="&#xE921;"/>
          <Button x:Name="BtnClose" Style="{StaticResource WinBtn}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <!-- Body -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Border Grid.Column="0" Background="{StaticResource Bg1}" CornerRadius="0,0,0,14">
          <DockPanel Margin="14,8,14,14">
            <StackPanel DockPanel.Dock="Top">
              <Button x:Name="NavBackup" Style="{StaticResource Nav}" Tag="active">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE74E;" FontSize="15" Width="24"/><TextBlock Text="Backup" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel>
              </Button>
              <Button x:Name="NavRestore" Style="{StaticResource Nav}" Margin="0,4,0,0">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE7B8;" FontSize="15" Width="24"/><TextBlock Text="Restore" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel>
              </Button>
              <Button x:Name="NavAbout" Style="{StaticResource Nav}" Margin="0,4,0,0">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE946;" FontSize="15" Width="24"/><TextBlock Text="About" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel>
              </Button>
            </StackPanel>
            <StackPanel DockPanel.Dock="Bottom" VerticalAlignment="Bottom">
              <Border Height="1" Background="{StaticResource Stroke}" Margin="4,0,4,12"/>
              <TextBlock Text="v1.1 - local &amp; offline" Foreground="{StaticResource Muted}" FontSize="11" Margin="6,0"/>
              <TextBlock Text="Nothing leaves this PC." Foreground="{StaticResource Muted}" FontSize="11" Margin="6,4,6,0"/>
            </StackPanel>
            <Grid/>
          </DockPanel>
        </Border>

        <!-- Content -->
        <Grid Grid.Column="1">

          <!-- BACKUP -->
          <Grid x:Name="PanelBackup" Margin="24,10,24,20">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

            <StackPanel Grid.Row="0">
              <TextBlock Text="Create a backup" FontSize="22" FontWeight="Bold"/>
              <TextBlock Text="Pick what to save before you wipe Windows. Restore it all on the fresh install." Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
            </StackPanel>

            <!-- Options bar -->
            <Border Grid.Row="1" Background="{StaticResource Bg2}" CornerRadius="12" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="16" Margin="0,16,0,14">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="DESTINATION" Foreground="{StaticResource Muted}" FontSize="10" FontWeight="Bold"/>
                  <Grid Margin="0,6,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Background="{StaticResource Bg0}" CornerRadius="9" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Height="38">
                      <TextBlock x:Name="TxtDest" Text="Choose a USB drive, D:, or cloud folder..." Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="12,0" TextTrimming="CharacterEllipsis"/>
                    </Border>
                    <Button x:Name="BtnBrowseDest" Grid.Column="1" Style="{StaticResource Ghost}" Margin="8,0,0,0">
                      <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8B7;" FontSize="13"/><TextBlock Text="Browse" Margin="6,0,0,0"/></StackPanel>
                    </Button>
                  </Grid>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="20,0,0,0">
                  <TextBlock Text="PRESET" Foreground="{StaticResource Muted}" FontSize="10" FontWeight="Bold"/>
                  <ComboBox x:Name="CmbPreset" Width="150" Margin="0,6,0,0">
                    <ComboBoxItem Content="Minimal"/><ComboBoxItem Content="Developer" IsSelected="True"/><ComboBoxItem Content="Everything"/><ComboBoxItem Content="Custom"/>
                  </ComboBox>
                </StackPanel>
              </Grid>
            </Border>

            <!-- Module list -->
            <Border Grid.Row="2" Background="{StaticResource Bg2}" CornerRadius="12" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
              <DockPanel>
                <Grid DockPanel.Dock="Top" Margin="16,12,16,6">
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="BtnSelectAll" Style="{StaticResource Nav}" Height="26"><TextBlock Text="Select all" Foreground="{StaticResource Accent}" FontSize="12"/></Button>
                    <Button x:Name="BtnSelectNone" Style="{StaticResource Nav}" Height="26" Margin="4,0,0,0"><TextBlock Text="Clear" Foreground="{StaticResource Muted}" FontSize="12"/></Button>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <CheckBox x:Name="ChkUpdate" FontWeight="Normal" Margin="0,0,14,0" ToolTip="Refresh the newest Phoenix-Backup folder in the destination instead of creating a new one (mirror copy)."><TextBlock Text="Update existing backup" FontSize="12" Foreground="{StaticResource Muted}"/></CheckBox>
                    <CheckBox x:Name="ChkChecksums" FontWeight="Normal" IsChecked="True" Margin="0,0,14,0" ToolTip="Write SHA-256 checksums so the backup can be verified later."><TextBlock Text="Checksums" FontSize="12" Foreground="{StaticResource Muted}"/></CheckBox>
                    <CheckBox x:Name="ChkAppFull" FontWeight="Normal"><TextBlock Text="Full AppData (incl. caches)" FontSize="12" Foreground="{StaticResource Muted}"/></CheckBox>
                  </StackPanel>
                </Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,4,16,12">
                  <StackPanel x:Name="PanelModules"/>
                </ScrollViewer>
              </DockPanel>
            </Border>

            <!-- Action bar -->
            <Border Grid.Row="3" Background="{StaticResource Bg2}" CornerRadius="12" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="16,12" Margin="0,14,0,0">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                  <CheckBox x:Name="ChkEncrypt" VerticalAlignment="Center"><TextBlock Text="Encrypt sensitive" FontSize="12"/></CheckBox>
                  <Border x:Name="PwWrap" Background="{StaticResource Bg0}" CornerRadius="9" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Height="34" Width="150" Margin="10,0,0,0" Visibility="Collapsed">
                    <PasswordBox x:Name="PwdBox" Background="Transparent" BorderThickness="0" Foreground="{StaticResource Txt}" VerticalContentAlignment="Center" Margin="10,0"/>
                  </Border>
                </StackPanel>
                <StackPanel Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock x:Name="LblTotal" Text="Select items to back up" Foreground="{StaticResource Muted}" FontSize="12" HorizontalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                  <Button x:Name="BtnSchedule" Style="{StaticResource Ghost}" Margin="0,0,10,0" ToolTip="Create a Windows scheduled task that runs this backup automatically (headless)."><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE823;" FontSize="13"/><TextBlock Text="Schedule" Margin="6,0,0,0"/></StackPanel></Button>
                  <Button x:Name="BtnEstimate" Style="{StaticResource Ghost}" Margin="0,0,10,0"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;" FontSize="13"/><TextBlock Text="Estimate size" Margin="6,0,0,0"/></StackPanel></Button>
                  <Button x:Name="BtnStartBackup" Style="{StaticResource Primary}" Width="170"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE74E;" FontSize="14"/><TextBlock Text="Start backup" Margin="8,0,0,0"/></StackPanel></Button>
                </StackPanel>
              </Grid>
            </Border>
          </Grid>

          <!-- RESTORE -->
          <Grid x:Name="PanelRestore" Margin="24,10,24,20" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel Grid.Row="0">
              <TextBlock Text="Restore a backup" FontSize="22" FontWeight="Bold"/>
              <TextBlock Text="Point to a Phoenix backup folder, choose what to bring back." Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
            </StackPanel>
            <Border Grid.Row="1" Background="{StaticResource Bg2}" CornerRadius="12" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="16" Margin="0,16,0,14">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="BACKUP FOLDER" Foreground="{StaticResource Muted}" FontSize="10" FontWeight="Bold"/>
                  <Border Background="{StaticResource Bg0}" CornerRadius="9" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Height="38" Margin="0,6,0,0">
                    <TextBlock x:Name="TxtSrc" Text="Select a Phoenix-Backup-... folder" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="12,0" TextTrimming="CharacterEllipsis"/>
                  </Border>
                  <TextBlock x:Name="LblManifestInfo" Foreground="{StaticResource Muted}" FontSize="12" Margin="2,8,0,0"/>
                </StackPanel>
                <Button x:Name="BtnBrowseSrc" Grid.Column="1" Style="{StaticResource Ghost}" Margin="10,18,0,0" VerticalAlignment="Top">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8B7;" FontSize="13"/><TextBlock Text="Open backup" Margin="6,0,0,0"/></StackPanel>
                </Button>
              </Grid>
            </Border>
            <Border Grid.Row="2" Background="{StaticResource Bg2}" CornerRadius="12" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,12">
                <StackPanel x:Name="PanelRestoreModules">
                  <TextBlock Text="Open a backup folder to see what's inside." Foreground="{StaticResource Muted}" HorizontalAlignment="Center" Margin="0,40"/>
                </StackPanel>
              </ScrollViewer>
            </Border>
            <Border Grid.Row="3" Background="{StaticResource Bg2}" CornerRadius="12" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="16,12" Margin="0,14,0,0">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                  <Border x:Name="PwRestoreWrap" Background="{StaticResource Bg0}" CornerRadius="9" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Height="34" Width="180" Visibility="Collapsed">
                    <Grid><PasswordBox x:Name="PwdRestore" Background="Transparent" BorderThickness="0" Foreground="{StaticResource Txt}" VerticalContentAlignment="Center" Margin="10,0"/></Grid>
                  </Border>
                  <TextBlock x:Name="LblVaultHint" Text="" Foreground="{StaticResource Warn}" FontSize="12" VerticalAlignment="Center" Margin="10,0,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                  <Button x:Name="BtnCompare" Style="{StaticResource Ghost}" Margin="0,0,10,0" IsEnabled="False" ToolTip="Compare this backup with another one: modules, files and package/extension lists added, removed or changed."><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8AB;" FontSize="13"/><TextBlock Text="Compare" Margin="6,0,0,0"/></StackPanel></Button>
                  <Button x:Name="BtnVerify" Style="{StaticResource Ghost}" Margin="0,0,10,0" IsEnabled="False" ToolTip="Re-hash every file against checksums.sha256 and check the vault."><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" FontSize="13"/><TextBlock Text="Verify" Margin="6,0,0,0"/></StackPanel></Button>
                  <Button x:Name="BtnDryRun" Style="{StaticResource Ghost}" Margin="0,0,10,0" IsEnabled="False" ToolTip="Show what restore would change on this PC without touching anything."><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8FD;" FontSize="13"/><TextBlock Text="Dry run" Margin="6,0,0,0"/></StackPanel></Button>
                  <Button x:Name="BtnStartRestore" Style="{StaticResource Primary}" Width="170" IsEnabled="False"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE7B8;" FontSize="14"/><TextBlock Text="Start restore" Margin="8,0,0,0"/></StackPanel></Button>
                </StackPanel>
              </Grid>
            </Border>
          </Grid>

          <!-- ABOUT -->
          <Grid x:Name="PanelAbout" Margin="24,10,24,20" Visibility="Collapsed">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <TextBlock Text="About Phoenix" FontSize="22" FontWeight="Bold"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,8,0,0" Text="A local, offline backup &amp; restore tool for moving to a fresh Windows install. It captures your apps, dev environment, Windows settings, app configs and files - then puts them back on the new PC."/>
                <Border Background="{StaticResource Bg2}" CornerRadius="12" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="18" Margin="0,18,0,0">
                  <StackPanel>
                    <TextBlock Text="Standout features" FontWeight="Bold" FontSize="15" Foreground="{StaticResource Accent}"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Text="- AES-256 encrypted vault (PBKDF2-SHA256 + HMAC integrity) for SSH keys, Wi-Fi passwords, PuTTY, git credentials &amp; browser profiles"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- manifest.json + checksums.sha256 + phoenix.log in every backup; Verify re-hashes everything"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Dry run shows exactly what restore would change before it touches anything"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Smart AppData mode skips caches; pick apps individually; add any custom folder"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Browser bookmarks &amp; profiles, installed-programs checklist, full WSL export/import"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Creates a System Restore Point before restoring Windows settings"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Reinstalls apps, editor extensions, npm/pip/cargo/dotnet globals and PowerShell modules"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Update-in-place backups + Schedule button for unattended headless runs"/>
                  </StackPanel>
                </Border>
                <Border Background="#20F59E0B" CornerRadius="12" BorderBrush="{StaticResource Warn}" BorderThickness="1" Padding="16" Margin="0,14,0,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource Icon}" Text="&#xE7BA;" FontSize="18" Foreground="{StaticResource Warn}" VerticalAlignment="Top"/>
                    <TextBlock TextWrapping="Wrap" Margin="12,0,0,0" Foreground="{StaticResource Txt}" Text="Some items (Wi-Fi, scheduled tasks, default apps, system restore point) need Administrator. Use 'Run as admin' in the title bar for a complete backup/restore."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </Grid>

          <!-- OVERLAY -->
          <Border x:Name="Overlay" Background="#CC0B0F17" Visibility="Collapsed">
            <Border Background="{StaticResource Bg1}" CornerRadius="14" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Width="700" Height="500" VerticalAlignment="Center" HorizontalAlignment="Center">
              <Grid Margin="22">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <StackPanel Grid.Row="0">
                  <TextBlock x:Name="OvTitle" Text="Working..." FontSize="18" FontWeight="Bold"/>
                  <TextBlock x:Name="OvStatus" Text="" Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
                </StackPanel>
                <Border Grid.Row="1" Height="8" CornerRadius="4" Background="{StaticResource Bg0}" Margin="0,16,0,0">
                  <Border x:Name="OvBar" HorizontalAlignment="Left" Width="0" CornerRadius="4">
                    <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#FB8C3E" Offset="0"/><GradientStop Color="#F97316" Offset="1"/></LinearGradientBrush></Border.Background>
                  </Border>
                </Border>
                <Border Grid.Row="2" Background="{StaticResource Bg0}" CornerRadius="10" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Margin="0,16,0,0">
                  <Grid>
                    <TextBox x:Name="OvLog" Background="Transparent" BorderThickness="0" Foreground="{StaticResource Txt}" FontFamily="Cascadia Mono, Consolas" FontSize="12" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="12" VerticalContentAlignment="Top"/>
                    <ScrollViewer x:Name="OvReport" VerticalScrollBarVisibility="Auto" Padding="12,8" Visibility="Collapsed">
                      <StackPanel x:Name="OvReportPanel"/>
                    </ScrollViewer>
                  </Grid>
                </Border>
                <Grid Grid.Row="3" Margin="0,16,0,0">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                    <TextBlock x:Name="OvSummary" Text="" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="BtnToggleLog" Style="{StaticResource Ghost}" Margin="0,0,10,0" Visibility="Collapsed"><TextBlock x:Name="TxtToggleLog" Text="Show log"/></Button>
                    <Button x:Name="BtnOpenFolder" Style="{StaticResource Ghost}" Margin="0,0,10,0" Visibility="Collapsed"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8B7;" FontSize="13"/><TextBlock Text="Open folder" Margin="6,0,0,0"/></StackPanel></Button>
                    <Button x:Name="BtnCancelOp" Style="{StaticResource Ghost}" Width="100"><TextBlock Text="Cancel"/></Button>
                    <Button x:Name="BtnCloseOv" Style="{StaticResource Primary}" Width="100" Visibility="Collapsed"><TextBlock Text="Done"/></Button>
                  </StackPanel>
                </Grid>
              </Grid>
            </Border>
          </Border>

        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@
#endregion

#region ------------------------------------------------------------ Load window
$reader  = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$window  = [Windows.Markup.XamlReader]::Load($reader)
function C($n){ $window.FindName($n) }

$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# Phoenix.exe sets PHOENIX_EXE so relaunch-as-admin and scheduled tasks point back at the exe instead of Phoenix.cmd.
$Script:Launcher = if($env:PHOENIX_EXE -and (Test-Path -LiteralPath $env:PHOENIX_EXE)){ $env:PHOENIX_EXE } else { Join-Path $PSScriptRoot 'Phoenix.cmd' }
if($Script:IsAdmin){ (C 'AdminBadge').Visibility='Visible' } else { (C 'BtnElevate').Visibility='Visible' }
#endregion

#region ------------------------------------------------------------ Helpers (UI thread)
function Format-Bytes($b){ if($null -eq $b){return '0 B'}; if($b -ge 1GB){'{0:N2} GB' -f ($b/1GB)} elseif($b -ge 1MB){'{0:N1} MB' -f ($b/1MB)} elseif($b -ge 1KB){'{0:N0} KB' -f ($b/1KB)} else {"$b B"} }

$Script:BackupChecks = @{}   # id -> checkbox
$Script:BackupSizes  = @{}   # id -> size label
$Script:RestoreChecks= @{}
$Script:Dest = $null
$Script:Src  = $null

function New-ModuleRow($module, $checked, [switch]$forRestore, $noteText){
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,5,0,5'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width='Auto'
    $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)

    $left = New-Object System.Windows.Controls.StackPanel
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $module.Name; $cb.IsChecked = $checked
    $left.Children.Add($cb) | Out-Null

    $descText = if($forRestore -and $noteText){ $noteText } else { $module.Desc }
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text=$descText; $desc.Foreground=$window.FindResource('Muted'); $desc.FontSize=12
    $desc.TextWrapping='Wrap'; $desc.Margin='29,2,20,0'
    $left.Children.Add($desc) | Out-Null

    if($module.Sensitive -or $module.Admin){
        $chips = New-Object System.Windows.Controls.StackPanel; $chips.Orientation='Horizontal'; $chips.Margin='29,6,0,0'
        if($module.Sensitive){
            $b=New-Object System.Windows.Controls.Border; $b.CornerRadius='6'; $b.Background=$window.FindResource('Bg3'); $b.Padding='7,2'; $b.Margin='0,0,6,0'
            $sp=New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'
            $g=New-Object System.Windows.Controls.TextBlock; $g.Text=[char]0xE72E; $g.FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets'; $g.FontSize=10; $g.Foreground=$window.FindResource('Warn')
            $t=New-Object System.Windows.Controls.TextBlock; $t.Text='sensitive'; $t.FontSize=10; $t.Foreground=$window.FindResource('Muted'); $t.Margin='5,0,0,0'
            $sp.Children.Add($g)|Out-Null; $sp.Children.Add($t)|Out-Null; $b.Child=$sp; $chips.Children.Add($b)|Out-Null
        }
        if($module.Admin){
            $b=New-Object System.Windows.Controls.Border; $b.CornerRadius='6'; $b.Background=$window.FindResource('Bg3'); $b.Padding='7,2'
            $sp=New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'
            $g=New-Object System.Windows.Controls.TextBlock; $g.Text=[char]0xEA18; $g.FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets'; $g.FontSize=10; $g.Foreground=$window.FindResource('Good')
            $t=New-Object System.Windows.Controls.TextBlock; $t.Text='admin'; $t.FontSize=10; $t.Foreground=$window.FindResource('Muted'); $t.Margin='5,0,0,0'
            $sp.Children.Add($g)|Out-Null; $sp.Children.Add($t)|Out-Null; $b.Child=$sp; $chips.Children.Add($b)|Out-Null
        }
        $left.Children.Add($chips) | Out-Null
    }

    [System.Windows.Controls.Grid]::SetColumn($left,0); $row.Children.Add($left) | Out-Null

    $size = New-Object System.Windows.Controls.TextBlock
    $size.Foreground=$window.FindResource('Muted'); $size.FontSize=12; $size.VerticalAlignment='Center'; $size.Text=''
    [System.Windows.Controls.Grid]::SetColumn($size,1); $row.Children.Add($size) | Out-Null

    return @{ Row=$row; Check=$cb; Size=$size; Left=$left }
}

$Script:AppChecks=@{}; $Script:AppSizeLbls=@{}
function New-AppPicker {
    $wrap = New-Object System.Windows.Controls.WrapPanel; $wrap.Margin='29,8,0,0'
    foreach($a in $Script:AppDataMap){
        if(-not (Test-Path -LiteralPath $a.Src)){ continue }
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.IsChecked=$true; $cb.FontWeight='Normal'; $cb.Margin='0,0,16,6'
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'
        $n = New-Object System.Windows.Controls.TextBlock; $n.Text=$a.Name; $n.FontSize=12
        $s = New-Object System.Windows.Controls.TextBlock; $s.Text=''; $s.FontSize=11; $s.Foreground=$window.FindResource('Muted'); $s.Margin='6,0,0,0'
        $sp.Children.Add($n) | Out-Null; $sp.Children.Add($s) | Out-Null; $cb.Content=$sp
        $Script:AppChecks[$a.Name]=$cb; $Script:AppSizeLbls[$a.Name]=$s
        $wrap.Children.Add($cb) | Out-Null
    }
    if($wrap.Children.Count -eq 0){ $t=New-Object System.Windows.Controls.TextBlock; $t.Text='No known app configs found on this PC.'; $t.FontSize=12; $t.Foreground=$window.FindResource('Muted'); $wrap.Children.Add($t) | Out-Null }
    return $wrap
}
function Get-AppSelection { @($Script:AppChecks.Keys | Where-Object { $Script:AppChecks[$_].IsChecked }) }

$Script:CustomPanel=$null; $Script:CustomSizeLbls=@{}
function Refresh-CustomList {
    $p=$Script:CustomPanel; if(-not $p){ return }; $p.Children.Clear(); $Script:CustomSizeLbls.Clear()
    foreach($f in @($Script:Settings.CustomFolders)){
        $row=New-Object System.Windows.Controls.Grid; $row.Margin='0,0,0,4'
        $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='*'; $c2=New-Object System.Windows.Controls.ColumnDefinition; $c2.Width='Auto'; $c3=New-Object System.Windows.Controls.ColumnDefinition; $c3.Width='Auto'
        $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2); $row.ColumnDefinitions.Add($c3)
        $t=New-Object System.Windows.Controls.TextBlock; $t.Text=$f; $t.FontSize=12; $t.TextTrimming='CharacterEllipsis'; $t.VerticalAlignment='Center'; $t.ToolTip=$f
        $s=New-Object System.Windows.Controls.TextBlock; $s.Text=''; $s.FontSize=11; $s.Foreground=$window.FindResource('Muted'); $s.VerticalAlignment='Center'; $s.Margin='10,0'
        $b=New-Object System.Windows.Controls.Button; $b.Style=$window.FindResource('Nav'); $b.Height=24; $b.ToolTip='Remove'
        $x=New-Object System.Windows.Controls.TextBlock; $x.Text=[char]0xE711; $x.FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets'; $x.FontSize=10; $x.Foreground=$window.FindResource('Muted'); $b.Content=$x
        $b.Add_Click({ $Script:Settings.CustomFolders=@($Script:Settings.CustomFolders | Where-Object { $_ -ne $f }); Save-Settings; Refresh-CustomList }.GetNewClosure()) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($t,0); [System.Windows.Controls.Grid]::SetColumn($s,1); [System.Windows.Controls.Grid]::SetColumn($b,2)
        $row.Children.Add($t) | Out-Null; $row.Children.Add($s) | Out-Null; $row.Children.Add($b) | Out-Null
        $Script:CustomSizeLbls[$f]=$s
        $p.Children.Add($row) | Out-Null
    }
}
function New-CustomFolderBlock {
    $sp=New-Object System.Windows.Controls.StackPanel; $sp.Margin='29,8,0,0'
    $Script:CustomPanel=New-Object System.Windows.Controls.StackPanel
    $btn=New-Object System.Windows.Controls.Button; $btn.Style=$window.FindResource('Ghost'); $btn.Height=28; $btn.HorizontalAlignment='Left'; $btn.Margin='0,4,0,0'
    $bt=New-Object System.Windows.Controls.TextBlock; $bt.Text='Add folder...'; $bt.FontSize=12; $btn.Content=$bt
    $btn.Add_Click({
        $dlg=New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description='Add a folder to back up (restored to the same path)'
        if($dlg.ShowDialog() -eq 'OK'){
            $pth=$dlg.SelectedPath
            if(@($Script:Settings.CustomFolders) -notcontains $pth){ $Script:Settings.CustomFolders=@($Script:Settings.CustomFolders)+$pth; Save-Settings; Refresh-CustomList }
            $Script:BackupChecks['user_custom'].IsChecked=$true; Update-BackupTotal
        }
    }) | Out-Null
    $sp.Children.Add($Script:CustomPanel) | Out-Null; $sp.Children.Add($btn) | Out-Null
    Refresh-CustomList
    return $sp
}

$Script:ReportShown=$false
function Show-Overlay($title){
    (C 'Overlay').Visibility='Visible'; (C 'OvTitle').Text=$title; (C 'OvStatus').Text=''; (C 'OvLog').Text=''; (C 'OvSummary').Text=''
    (C 'OvBar').Width=0
    (C 'OvLog').Visibility='Visible'; (C 'OvReport').Visibility='Collapsed'; (C 'OvReportPanel').Children.Clear()
    (C 'BtnCancelOp').Visibility='Visible'; (C 'BtnCloseOv').Visibility='Collapsed'; (C 'BtnOpenFolder').Visibility='Collapsed'; (C 'BtnToggleLog').Visibility='Collapsed'
    $Script:ReportShown=$false
}
function Show-Report($title,$items){
    $panel=C 'OvReportPanel'; $panel.Children.Clear()
    $counts=@{ ok=0; manual=0; skip=0; error=0; changed=0 }
    foreach($it in @($items)){
        $st=[string]$it.Status; if(-not $counts.ContainsKey($st)){ $st='ok' }; $counts[$st]++
        $row=New-Object System.Windows.Controls.Grid; $row.Margin='0,4,0,4'
        $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='26'; $c2=New-Object System.Windows.Controls.ColumnDefinition; $c2.Width='*'
        $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)
        $ic=New-Object System.Windows.Controls.TextBlock; $ic.FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets'; $ic.FontSize=13; $ic.VerticalAlignment='Top'; $ic.Margin='0,2,0,0'
        switch($st){
            'ok'     { $ic.Text=[char]0xE73E; $ic.Foreground=$window.FindResource('Good') }
            'manual' { $ic.Text=[char]0xE7BA; $ic.Foreground=$window.FindResource('Warn') }
            'skip'   { $ic.Text=[char]0xE738; $ic.Foreground=$window.FindResource('Muted') }
            'error'  { $ic.Text=[char]0xEA39; $ic.Foreground=$window.FindResource('Bad') }
            'changed'{ $ic.Text=[char]0xE8AB; $ic.Foreground=$window.FindResource('Accent') }
        }
        $sp=New-Object System.Windows.Controls.StackPanel
        $n=New-Object System.Windows.Controls.TextBlock; $n.Text=[string]$it.Name; $n.FontWeight='SemiBold'; $n.FontSize=13
        $sp.Children.Add($n) | Out-Null
        if($it.Note){ $d=New-Object System.Windows.Controls.TextBlock; $d.Text=[string]$it.Note; $d.FontSize=12; $d.Foreground=$window.FindResource('Muted'); $d.TextWrapping='Wrap'; $sp.Children.Add($d) | Out-Null }
        [System.Windows.Controls.Grid]::SetColumn($ic,0); [System.Windows.Controls.Grid]::SetColumn($sp,1)
        $row.Children.Add($ic) | Out-Null; $row.Children.Add($sp) | Out-Null
        $panel.Children.Add($row) | Out-Null
    }
    (C 'OvSummary').Text = if($title -like 'Changes:*'){ ("{0} unchanged  -  {1} changed  -  {2} not comparable" -f $counts.ok,$counts.changed,$counts.skip) } else { ("{0} ok  -  {1} need attention  -  {2} skipped  -  {3} failed" -f $counts.ok,$counts.manual,$counts.skip,$counts.error) }
    (C 'OvTitle').Text=$title
    (C 'OvReport').Visibility='Visible'; (C 'OvLog').Visibility='Collapsed'
    (C 'BtnToggleLog').Visibility='Visible'; (C 'TxtToggleLog').Text='Show log'
    $Script:ReportShown=$true
}

function New-CategoryCard($catName){
    $card = New-Object System.Windows.Controls.Border
    $card.Background=$window.FindResource('Bg3'); $card.CornerRadius='10'; $card.BorderBrush=$window.FindResource('Stroke'); $card.BorderThickness='1'
    $card.Padding='14,10'; $card.Margin='0,0,0,10'
    $sp = New-Object System.Windows.Controls.StackPanel
    $hd = New-Object System.Windows.Controls.TextBlock
    $hd.Text=$catName.ToUpper(); $hd.FontSize=11; $hd.FontWeight='Bold'; $hd.Foreground=$window.FindResource('Accent'); $hd.Margin='0,0,0,4'
    $sp.Children.Add($hd) | Out-Null
    $card.Child=$sp
    return @{ Card=$card; Stack=$sp }
}

function Build-BackupTree {
    $panel = C 'PanelModules'; $panel.Children.Clear(); $Script:BackupChecks.Clear(); $Script:BackupSizes.Clear()
    foreach($cat in $Script:Categories){
        $mods = $Script:Modules | Where-Object { $_.Cat -eq $cat }
        if(-not $mods){ continue }
        $cc = New-CategoryCard $cat
        foreach($m in $mods){
            $r = New-ModuleRow $m $false
            if($m.Id -eq 'app_appdata'){ $r.Left.Children.Add((New-AppPicker)) | Out-Null }
            elseif($m.Id -eq 'user_custom'){ $r.Left.Children.Add((New-CustomFolderBlock)) | Out-Null }
            $cc.Stack.Children.Add($r.Row) | Out-Null
            $Script:BackupChecks[$m.Id]=$r.Check; $Script:BackupSizes[$m.Id]=$r.Size
            $r.Check.Add_Click({ Update-BackupTotal }) | Out-Null
        }
        $panel.Children.Add($cc.Card) | Out-Null
    }
}

function Apply-Preset($preset){
    foreach($m in $Script:Modules){
        $cb=$Script:BackupChecks[$m.Id]
        if($preset -eq 'Everything'){ $cb.IsChecked=$true }
        elseif($preset -eq 'Custom'){ }
        else { $cb.IsChecked = ($m.Presets -contains $preset) }
    }
    Update-BackupTotal
}

function Get-CheckedIds {
    $ids=@(); foreach($m in $Script:Modules){ if($Script:BackupChecks[$m.Id].IsChecked){ $ids+=$m.Id } }; return $ids
}
function Update-BackupTotal {
    $ids=Get-CheckedIds
    $known=0; $has=$false
    foreach($id in $ids){ if($Script:BackupSizes[$id].Tag){ $known+=[long]$Script:BackupSizes[$id].Tag; $has=$true } }
    if($ids.Count -eq 0){ (C 'LblTotal').Text='Select items to back up' }
    elseif($has){ (C 'LblTotal').Text = ("{0} items  -  ~{1} measured" -f $ids.Count, (Format-Bytes $known)) }
    else { (C 'LblTotal').Text = ("{0} items selected" -f $ids.Count) }
}
#endregion

#region ------------------------------------------------------------ Background runspace plumbing
$Script:sync = [hashtable]::Synchronized(@{})
$Script:sync.Events = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$Script:sync.Cancel = $false
$Script:sync.Meta = @{}
foreach($m in $Script:Modules){ $Script:sync.Meta[$m.Id]=@{ Name=$m.Name; Cat=$m.Cat; Sensitive=[bool]$m.Sensitive } }
$Script:PSInstance=$null; $Script:PSHandle=$null; $Script:RS=$null

$Script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:Timer.Interval=[TimeSpan]::FromMilliseconds(110)
$Script:Timer.Add_Tick({
    while($Script:sync.Events.Count -gt 0){
        $e = $Script:sync.Events.Dequeue()
        switch($e.Type){
            'Log' {
                $lvl=$e.Data.Level; $pre=switch($lvl){ 'Ok'{'[ok] '} 'Warn'{'[!] '} 'Error'{'[x] '} default{''} }
                $box=C 'OvLog'; $box.AppendText("$pre$($e.Data.Msg)`r`n"); $box.ScrollToEnd()
            }
            'Progress' {
                $bar=C 'OvBar'; $track=$bar.Parent
                $bar.Width = [math]::Max(0, ($track.ActualWidth * ($e.Data.Pct/100.0)))
                (C 'OvStatus').Text = $e.Data.Status
            }
            'Size' {
                $lbl=$Script:BackupSizes[$e.Data.Id]; if($lbl){ $lbl.Tag=$e.Data.Bytes; $lbl.Text=(Format-Bytes $e.Data.Bytes) }
            }
            'AppSize'    { $l=$Script:AppSizeLbls[$e.Data.Name]; if($l){ $l.Text=(Format-Bytes $e.Data.Bytes) } }
            'CustomSize' { $l=$Script:CustomSizeLbls[$e.Data.Path]; if($l){ $l.Text=(Format-Bytes $e.Data.Bytes) } }
            'Report'     { Show-Report $e.Data.Title $e.Data.Items }
            'EstimateDone' { Update-BackupTotal }
            'Done' {
                $Script:Timer.Stop()
                (C 'BtnCancelOp').Visibility='Collapsed'; (C 'BtnCloseOv').Visibility='Visible'
                if(($Script:sync.Result -eq 'backup' -or $Script:sync.Result -eq 'compare') -and $Script:sync.OutputPath){ (C 'BtnOpenFolder').Visibility='Visible'; $Script:LastOutput=$Script:sync.OutputPath }
                if($Script:sync.Op -eq 'Estimate'){ (C 'Overlay').Visibility='Collapsed' }
                elseif(-not $Script:ReportShown){ (C 'OvTitle').Text = if($Script:sync.Result -eq 'error'){'Finished with errors'} else {'All done'} }
                if($Script:PSInstance){ try{ $Script:PSInstance.EndInvoke($Script:PSHandle) }catch{}; $Script:PSInstance.Dispose(); $Script:PSInstance=$null }
                if($Script:RS){ $Script:RS.Close(); $Script:RS=$null }
            }
        }
    }
})

function Start-Worker($op){
    $Script:sync.Op=$op; $Script:sync.Cancel=$false; $Script:sync.Result=$null; $Script:sync.OutputPath=$null
    $Script:sync.Mirror=$false; $Script:sync.LogPath=$null; $Script:sync.Console=$false; $Script:sync.IsAdmin=$Script:IsAdmin
    $Script:sync.AppDataMap=$Script:AppDataMap; $Script:sync.AppDataSel=Get-AppSelection; $Script:sync.AppDataFull=[bool](C 'ChkAppFull').IsChecked
    $Script:sync.Custom=@($Script:Settings.CustomFolders)
    $Script:sync.UpdateExisting=[bool](C 'ChkUpdate').IsChecked; $Script:sync.NoChecksums=-not [bool](C 'ChkChecksums').IsChecked
    $Script:sync.SecureIds=@($Script:ManifestSecureIds)
    $Script:RS = [RunspaceFactory]::CreateRunspace()
    $Script:RS.ApartmentState='STA'; $Script:RS.ThreadOptions='ReuseThread'; $Script:RS.Open()
    $Script:RS.SessionStateProxy.SetVariable('sync',$Script:sync)
    $Script:PSInstance = [PowerShell]::Create(); $Script:PSInstance.Runspace=$Script:RS
    $Script:PSInstance.AddScript($Script:WorkerText) | Out-Null
    $Script:PSHandle = $Script:PSInstance.BeginInvoke()
    $Script:Timer.Start()
}
#endregion

#region ------------------------------------------------------------ Event wiring
(C 'TitleBar').Add_MouseLeftButtonDown({ $window.DragMove() })
(C 'BtnMin').Add_Click({ $window.WindowState='Minimized' })
(C 'BtnClose').Add_Click({ $window.Close() })
(C 'BtnElevate').Add_Click({
    try{ Start-Process $Script:Launcher -Verb RunAs; $window.Close() }catch{}
})

function Set-Nav($active){
    foreach($n in @('NavBackup','NavRestore','NavAbout')){ (C $n).Tag=$null }
    foreach($p in @('PanelBackup','PanelRestore','PanelAbout')){ (C $p).Visibility='Collapsed' }
    (C $active).Tag='active'
    $panel = switch($active){ 'NavBackup'{'PanelBackup'} 'NavRestore'{'PanelRestore'} 'NavAbout'{'PanelAbout'} }
    (C $panel).Visibility='Visible'
}
(C 'NavBackup').Add_Click({ Set-Nav 'NavBackup' })
(C 'NavRestore').Add_Click({ Set-Nav 'NavRestore' })
(C 'NavAbout').Add_Click({ Set-Nav 'NavAbout' })

(C 'ChkEncrypt').Add_Click({ (C 'PwWrap').Visibility = if((C 'ChkEncrypt').IsChecked){'Visible'}else{'Collapsed'} })

(C 'CmbPreset').Add_SelectionChanged({
    $sel=(C 'CmbPreset').SelectedItem; if($sel){ Apply-Preset ($sel.Content) }
})
(C 'BtnSelectAll').Add_Click({ foreach($m in $Script:Modules){ $Script:BackupChecks[$m.Id].IsChecked=$true }; (C 'CmbPreset').SelectedIndex=3; Update-BackupTotal })
(C 'BtnSelectNone').Add_Click({ foreach($m in $Script:Modules){ $Script:BackupChecks[$m.Id].IsChecked=$false }; (C 'CmbPreset').SelectedIndex=3; Update-BackupTotal })

(C 'BtnBrowseDest').Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description='Choose where to save the backup'
    if($Script:Dest){ $dlg.SelectedPath=$Script:Dest }
    if($dlg.ShowDialog() -eq 'OK'){ Set-Dest $dlg.SelectedPath; $Script:Settings.LastDest=$dlg.SelectedPath; Save-Settings }
})
function Set-Dest($p){ $Script:Dest=$p; (C 'TxtDest').Text=$p; (C 'TxtDest').Foreground=$window.FindResource('Txt') }

(C 'BtnEstimate').Add_Click({
    $ids=Get-CheckedIds; if($ids.Count -eq 0){ return }
    $Script:sync.Ids=$ids
    Show-Overlay 'Estimating size...'
    Start-Worker 'Estimate'
})

(C 'BtnStartBackup').Add_Click({
    $ids=Get-CheckedIds
    if($ids.Count -eq 0){ [System.Windows.MessageBox]::Show('Select at least one item.','Phoenix') | Out-Null; return }
    if(-not $Script:Dest){ [System.Windows.MessageBox]::Show('Choose a destination folder first.','Phoenix') | Out-Null; return }
    if((C 'ChkEncrypt').IsChecked -and -not (C 'PwdBox').Password){ [System.Windows.MessageBox]::Show('Enter a vault password or turn off encryption.','Phoenix') | Out-Null; return }
    if(-not (C 'ChkEncrypt').IsChecked){
        $sens=@($ids | Where-Object { $Script:ModuleById[$_].Sensitive } | ForEach-Object { $Script:ModuleById[$_].Name })
        if($sens.Count -gt 0 -and [System.Windows.MessageBox]::Show("Encryption is OFF. These will be written in plain text:`n`n - $($sens -join "`n - ")`n`nAnyone with the backup folder can read them. Continue anyway?",'Sensitive data unencrypted','YesNo','Warning') -ne 'Yes'){ return }
    }
    if(($ids -contains 'dev_wsl_export') -and [System.Windows.MessageBox]::Show('Full WSL export can take a long time and many GB. WSL will be shut down during export. Continue?','Phoenix','YesNo','Question') -ne 'Yes'){ return }
    $Script:sync.Ids=$ids; $Script:sync.Dest=$Script:Dest
    $Script:sync.Encrypt=[bool](C 'ChkEncrypt').IsChecked; $Script:sync.Password=(C 'PwdBox').Password
    Show-Overlay $(if((C 'ChkUpdate').IsChecked){'Updating backup...'}else{'Backing up...'})
    Start-Worker 'Backup'
})

(C 'BtnSchedule').Add_Click({
    $ids=Get-CheckedIds
    if($ids.Count -eq 0){ [System.Windows.MessageBox]::Show('Select the items to include first.','Phoenix') | Out-Null; return }
    if(-not $Script:Dest){ [System.Windows.MessageBox]::Show('Choose a destination folder first.','Phoenix') | Out-Null; return }
    if($ids -contains 'dev_wsl_export'){ [System.Windows.MessageBox]::Show('Untick "WSL distros (full export)" - it shuts WSL down and is not suitable for unattended runs.','Phoenix') | Out-Null; return }
    $r=[System.Windows.MessageBox]::Show("Create a Windows scheduled task that backs up the selected items to:`n$($Script:Dest)`n`nIt runs headless and updates the newest backup in place.`n`nYes = weekly (Sunday 20:00)`nNo = daily (20:00)",'Schedule backup','YesNoCancel','Question')
    if($r -eq 'Cancel'){ return }
    $args = "-Headless -Dest `"$($Script:Dest)`" -Items $($ids -join ',') -Update"
    if(-not (C 'ChkChecksums').IsChecked){ $args += ' -NoChecksums' }
    if((C 'ChkEncrypt').IsChecked){
        if(-not (C 'PwdBox').Password){ [System.Windows.MessageBox]::Show('Enter the vault password (it is stored for the scheduled task) or untick Encrypt.','Phoenix') | Out-Null; return }
        if([System.Windows.MessageBox]::Show('Scheduled encrypted backups read the password from the PHOENIX_VAULT_PASSWORD user environment variable. Store it now? It will be readable by anything running as your user.','Phoenix','YesNo','Warning') -ne 'Yes'){ return }
        [Environment]::SetEnvironmentVariable('PHOENIX_VAULT_PASSWORD',(C 'PwdBox').Password,'User'); $args += ' -Encrypt'
    }
    try{
        $trigger = if($r -eq 'Yes'){ New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '20:00' } else { New-ScheduledTaskTrigger -Daily -At '20:00' }
        $action  = New-ScheduledTaskAction -Execute $Script:Launcher -Argument $args -WorkingDirectory (Split-Path $Script:Launcher -Parent)
        $settings= New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'Phoenix Backup' -Action $action -Trigger $trigger -Settings $settings -Description 'Phoenix - Windows Migration Kit: scheduled headless backup' -Force | Out-Null
        [System.Windows.MessageBox]::Show("Task 'Phoenix Backup' created. Keep $(Split-Path $Script:Launcher -Leaf) where it is - the task runs it from:`n$(Split-Path $Script:Launcher -Parent)",'Phoenix') | Out-Null
    }catch{ [System.Windows.MessageBox]::Show("Could not create the task: $($_.Exception.Message)",'Phoenix') | Out-Null }
})

(C 'BtnCancelOp').Add_Click({ $Script:sync.Cancel=$true; (C 'OvStatus').Text='Cancelling...' })
(C 'BtnCloseOv').Add_Click({ (C 'Overlay').Visibility='Collapsed' })
(C 'BtnOpenFolder').Add_Click({ if($Script:LastOutput){ Start-Process explorer.exe $Script:LastOutput } })
(C 'BtnToggleLog').Add_Click({
    $showingLog = (C 'OvLog').Visibility -eq 'Visible'
    (C 'OvLog').Visibility = if($showingLog){'Collapsed'}else{'Visible'}
    (C 'OvReport').Visibility = if($showingLog){'Visible'}else{'Collapsed'}
    (C 'TxtToggleLog').Text = if($showingLog){'Show log'}else{'Show report'}
})

# ---- Restore side ----
function Load-Manifest($folder){
    $mf = Join-Path $folder 'manifest.json'
    if(-not (Test-Path -LiteralPath $mf)){ [System.Windows.MessageBox]::Show('No manifest.json in that folder. Pick a Phoenix-Backup-... folder.','Phoenix') | Out-Null; return }
    $man = Get-Content $mf -Raw | ConvertFrom-Json
    $Script:Src=$folder; (C 'TxtSrc').Text=$folder; (C 'TxtSrc').Foreground=$window.FindResource('Txt')
    $extras=@(); if($man.Encrypted){ $extras+='encrypted vault' }; if($man.Checksums){ $extras+='checksums' }; if($man.Cancelled){ $extras+='INCOMPLETE (cancelled)' }
    (C 'LblManifestInfo').Text = ("From {0}  -  {1}  -  {2} items{3}" -f $man.Machine, ([datetime]$man.Created).ToString('g'), @($man.Modules).Count, $(if($extras.Count){'  -  '+($extras -join ', ')}else{''}))

    $panel=C 'PanelRestoreModules'; $panel.Children.Clear(); $Script:RestoreChecks.Clear()
    $hasVault = [bool]$man.Vault
    # Which modules have data inside the vault (v1.0 manifests flag the module; v1.1 also lists SecurePaths).
    $Script:ManifestSecureIds = @($man.Modules | Where-Object { $_.Status -eq 'ok' -and ($_.Secure -eq $true -or @($_.SecurePaths).Count -gt 0) } | ForEach-Object { $_.Id })
    $byCat=@{}
    foreach($mod in $man.Modules){
        if($mod.Status -eq 'skip' -or $mod.Status -eq 'error'){ continue }
        $meta=$Script:ModuleById[$mod.Id]; if(-not $meta){ continue }
        if(-not $byCat.ContainsKey($meta.Cat)){ $byCat[$meta.Cat]=@() }
        $byCat[$meta.Cat] += ,@($meta,$mod)
    }
    foreach($cat in $Script:Categories){
        if(-not $byCat.ContainsKey($cat)){ continue }
        $cc=New-CategoryCard $cat
        foreach($pair in $byCat[$cat]){
            $meta=$pair[0]; $mod=$pair[1]
            $note = if($mod.Note){ "$($mod.Note)  -  $(Format-Bytes $mod.Size)" } else { "$(Format-Bytes $mod.Size)" }
            $r=New-ModuleRow $meta $true -forRestore -noteText $note
            $cc.Stack.Children.Add($r.Row) | Out-Null
            $Script:RestoreChecks[$mod.Id]=$r.Check
        }
        $panel.Children.Add($cc.Card) | Out-Null
    }
    (C 'BtnStartRestore').IsEnabled = ($Script:RestoreChecks.Count -gt 0)
    (C 'BtnDryRun').IsEnabled = ($Script:RestoreChecks.Count -gt 0)
    (C 'BtnVerify').IsEnabled = $true
    (C 'BtnCompare').IsEnabled = $true
    if($hasVault){ (C 'PwRestoreWrap').Visibility='Visible'; (C 'LblVaultHint').Text='Vault password needed for sensitive items' }
    else { (C 'PwRestoreWrap').Visibility='Collapsed'; (C 'LblVaultHint').Text='' }
    $Script:ManifestHasVault=$hasVault
}
function Get-RestoreIds { $ids=@(); foreach($k in $Script:RestoreChecks.Keys){ if($Script:RestoreChecks[$k].IsChecked){ $ids+=$k } }; return $ids }

(C 'BtnBrowseSrc').Add_Click({
    $dlg=New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description='Open a Phoenix backup folder'
    if($Script:Dest){ $dlg.SelectedPath=$Script:Dest }
    if($dlg.ShowDialog() -eq 'OK'){ Load-Manifest $dlg.SelectedPath }
})

(C 'BtnVerify').Add_Click({
    if(-not $Script:Src){ return }
    $Script:sync.RestoreSrc=$Script:Src; $Script:sync.Password=(C 'PwdRestore').Password
    Show-Overlay 'Verifying backup...'
    Start-Worker 'Verify'
})

(C 'BtnCompare').Add_Click({
    if(-not $Script:Src){ return }
    $dlg=New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description='Pick the other Phoenix backup to compare with'
    $dlg.SelectedPath=Split-Path $Script:Src -Parent
    if($dlg.ShowDialog() -ne 'OK'){ return }
    $other=$dlg.SelectedPath
    if($other.TrimEnd('\') -ieq $Script:Src.TrimEnd('\')){ [System.Windows.MessageBox]::Show('Pick a different backup than the one already open.','Phoenix') | Out-Null; return }
    if(-not (Test-Path -LiteralPath (Join-Path $other 'manifest.json'))){ [System.Windows.MessageBox]::Show('No manifest.json in that folder. Pick a Phoenix-Backup-... folder.','Phoenix') | Out-Null; return }
    $Script:sync.CompareA=$Script:Src; $Script:sync.CompareB=$other
    Show-Overlay 'Comparing backups...'
    Start-Worker 'Compare'
})

(C 'BtnDryRun').Add_Click({
    $ids=Get-RestoreIds
    if($ids.Count -eq 0){ [System.Windows.MessageBox]::Show('Select at least one item.','Phoenix') | Out-Null; return }
    $Script:sync.Ids=$ids; $Script:sync.RestoreSrc=$Script:Src; $Script:sync.Password=(C 'PwdRestore').Password
    Show-Overlay 'Dry run - planning restore...'
    Start-Worker 'DryRun'
})

(C 'BtnStartRestore').Add_Click({
    $ids=Get-RestoreIds
    if($ids.Count -eq 0){ [System.Windows.MessageBox]::Show('Select at least one item.','Phoenix') | Out-Null; return }
    $needVault = @($ids | Where-Object { $Script:ManifestSecureIds -contains $_ }).Count -gt 0
    if($Script:ManifestHasVault -and $needVault -and -not (C 'PwdRestore').Password){ [System.Windows.MessageBox]::Show('Enter the vault password.','Phoenix') | Out-Null; return }
    $msg="This will write files and settings to this PC. Continue?`n`nTip: use Dry run first to see exactly what will change."
    if([System.Windows.MessageBox]::Show($msg,'Confirm restore','YesNo','Warning') -ne 'Yes'){ return }
    $Script:sync.Ids=$ids; $Script:sync.RestoreSrc=$Script:Src; $Script:sync.Password=(C 'PwdRestore').Password
    Show-Overlay 'Restoring...'
    Start-Worker 'Restore'
})
#endregion

#region ------------------------------------------------------------ Init & show
Build-BackupTree
Apply-Preset 'Developer'
(C 'CmbPreset').SelectedIndex = 1
$Script:ManifestSecureIds=@()
if($Script:Settings.LastDest -and (Test-Path -LiteralPath $Script:Settings.LastDest)){ Set-Dest $Script:Settings.LastDest }
$window.Add_Closing({ try{ $Script:sync.Cancel=$true; if($Script:Timer){$Script:Timer.Stop()}; if($Script:PSInstance){$Script:PSInstance.Dispose()}; if($Script:RS){$Script:RS.Close()} }catch{} })
if(-not $env:PHOENIX_NO_SHOW){ $window.ShowDialog() | Out-Null }
#endregion
