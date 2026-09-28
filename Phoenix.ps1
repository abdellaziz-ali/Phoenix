#Requires -Version 5.1
<#
    Phoenix - Windows Migration Kit
    A self-contained backup & restore tool for migrating to a fresh Windows install.
    Run via Phoenix.cmd (launches Windows PowerShell in STA mode for WPF).
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing | Out-Null

#region ------------------------------------------------------------ Module catalog (UI metadata)
# Categories render in this order.
$Script:Categories = @('Applications','Developer Environment','Windows Settings','App Settings & Data','User Folders')

# Each module: Id, Cat, Name, Desc, Sensitive, Admin, Presets (Minimal/Developer). "Everything" = all.
$Script:Modules = @(
    @{ Id='apps_winget';   Cat='Applications'; Name='Installed apps (winget)';        Desc='Exports every winget/Store package so they reinstall unattended.'; Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='apps_ubundle';  Cat='Applications'; Name='UniGetUI bundle';                 Desc='Copies an apps.ubundle from your Desktop if present.';             Sensitive=$false; Admin=$false; Presets=@('Developer') }

    @{ Id='dev_vscode';    Cat='Developer Environment'; Name='Editor extensions';       Desc='VS Code, Insiders & Cursor extension lists.';                      Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='dev_node';      Cat='Developer Environment'; Name='Node globals';            Desc='Global npm packages + nvm/fnm installed versions.';                Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_python';    Cat='Developer Environment'; Name='Python packages';         Desc='pip freeze per installed Python version.';                         Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_rust';      Cat='Developer Environment'; Name='Rust toolchains';         Desc='rustup toolchains + globally installed cargo crates.';             Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_dotnet';    Cat='Developer Environment'; Name='.NET global tools';       Desc='dotnet tool list (global).';                                       Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_git';       Cat='Developer Environment'; Name='Git configuration';       Desc='.gitconfig and global ignore. Credentials go to the vault.';       Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='dev_ssh';       Cat='Developer Environment'; Name='SSH keys';                Desc='Your ~/.ssh folder (private keys).';                               Sensitive=$true;  Admin=$false; Presets=@('Developer') }
    @{ Id='dev_ps';        Cat='Developer Environment'; Name='PowerShell profile';      Desc='$PROFILE + installed module names.';                               Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_wsl';       Cat='Developer Environment'; Name='WSL distros (list)';      Desc='Records installed WSL distributions (informational).';             Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='dev_env';       Cat='Developer Environment'; Name='Environment variables';   Desc='User-scope variables incl. PATH.';                                 Sensitive=$false; Admin=$false; Presets=@('Developer') }

    @{ Id='win_wifi';      Cat='Windows Settings'; Name='Wi-Fi profiles';               Desc='Saved networks with passwords.';                                   Sensitive=$true;  Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='win_power';     Cat='Windows Settings'; Name='Power plans';                  Desc='Exports custom power schemes.';                                    Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_drives';    Cat='Windows Settings'; Name='Mapped network drives';        Desc='SMB drive mappings.';                                              Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_hosts';     Cat='Windows Settings'; Name='Hosts file';                   Desc='C:\Windows\System32\drivers\etc\hosts.';                           Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_tasks';     Cat='Windows Settings'; Name='Scheduled tasks';              Desc='Your non-system scheduled tasks.';                                 Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='win_explorer';  Cat='Windows Settings'; Name='Explorer & taskbar tweaks';    Desc='Explorer Advanced registry (show extensions, hidden files, etc.).'; Sensitive=$false; Admin=$false; Presets=@('Developer') }
    @{ Id='win_terminal';  Cat='Windows Settings'; Name='Windows Terminal';             Desc='settings.json (themes, profiles, keybindings).';                   Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='win_printers';  Cat='Windows Settings'; Name='Printers (list)';              Desc='Records installed printers (informational).';                      Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='win_defaultapps';Cat='Windows Settings'; Name='Default app associations';    Desc='File-type defaults (requires admin to export).';                   Sensitive=$false; Admin=$true;  Presets=@() }
    @{ Id='win_fonts';     Cat='Windows Settings'; Name='User-installed fonts';         Desc='Fonts you added under your profile.';                              Sensitive=$false; Admin=$false; Presets=@() }

    @{ Id='app_appdata';   Cat='App Settings & Data'; Name='App configs (Smart)';       Desc='Curated settings for OBS, Notepad++, PowerToys, editors, etc. Caches skipped.'; Sensitive=$false; Admin=$false; Presets=@('Minimal','Developer') }
    @{ Id='app_putty';     Cat='App Settings & Data'; Name='PuTTY sessions';            Desc='Saved sessions & host keys (registry).';                           Sensitive=$true;  Admin=$false; Presets=@('Developer') }

    @{ Id='user_documents';Cat='User Folders'; Name='Documents'; Desc='Mirror of your Documents folder.'; Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_desktop';  Cat='User Folders'; Name='Desktop';   Desc='Mirror of your Desktop folder.';   Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_pictures'; Cat='User Folders'; Name='Pictures';  Desc='Mirror of your Pictures folder.';  Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_downloads';Cat='User Folders'; Name='Downloads'; Desc='Mirror of your Downloads folder.'; Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_videos';   Cat='User Folders'; Name='Videos';    Desc='Mirror of your Videos folder.';    Sensitive=$false; Admin=$false; Presets=@() }
    @{ Id='user_music';    Cat='User Folders'; Name='Music';     Desc='Mirror of your Music folder.';     Sensitive=$false; Admin=$false; Presets=@() }
)
$Script:ModuleById = @{}
foreach ($m in $Script:Modules) { $Script:ModuleById[$m.Id] = $m }
#endregion

#region ------------------------------------------------------------ Worker (runs in background runspace)
$Script:WorkerText = @'
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

function Fmt-Bytes($b){ if($null -eq $b){return '0 B'}; if($b -ge 1GB){'{0:N2} GB' -f ($b/1GB)} elseif($b -ge 1MB){'{0:N1} MB' -f ($b/1MB)} elseif($b -ge 1KB){'{0:N0} KB' -f ($b/1KB)} else {"$b B"} }
function Emit($t,$d){ $sync.Events.Enqueue(@{ Type=$t; Data=$d }) }
function WL($m,$l){ if(-not $l){$l='Info'}; Emit 'Log' @{ Msg=$m; Level=$l } }
function Prog($p,$s){ Emit 'Progress' @{ Pct=$p; Status=$s } }
function EnsureDir($p){ if($p -and -not (Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function FolderSize($p){ if(-not (Test-Path -LiteralPath $p)){ return 0 }; try{ $s=(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if($null -eq $s){0}else{$s} }catch{ 0 } }
function CmdExists($n){ $null -ne (Get-Command $n -ErrorAction SilentlyContinue) }
function RelOf($root,$full){ $full.Substring($root.Length).TrimStart('\','/') }

function Robo($src,$dst,$smart){
    EnsureDir $dst
    $a = @($src, $dst, '/E','/R:1','/W:1','/NFL','/NDL','/NJH','/NJS','/NP')
    if($smart){ foreach($x in @('Cache','Code Cache','GPUCache','ShaderCache','Service Worker','CacheStorage','GrShaderCache','Crashpad','Crashpad_reports','logs','Log','tmp','Temp','blob_storage','DawnCache','workspaceStorage','globalStorage','History','CachedData','CachedExtensions','CachedExtensionVSIXs','Backups','Local Storage','Session Storage','IndexedDB','DawnGraphiteCache','WebStorage')){ $a += '/XD'; $a += $x } }
    & robocopy @a *>$null
    return $LASTEXITCODE
}

# ---- AES-256 file encryption (PBKDF2 key derivation, salt+IV prepended) ----
function Protect-File($inPath,$outPath,$pw){
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.GetBytes($iv)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw,$salt,200000)
    $aes = [System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Key=$kdf.GetBytes(32); $aes.IV=$iv
    $out = [System.IO.File]::Open($outPath,'Create'); $out.Write($salt,0,16); $out.Write($iv,0,16)
    $cs  = New-Object System.Security.Cryptography.CryptoStream($out,$aes.CreateEncryptor(),'Write')
    $in  = [System.IO.File]::OpenRead($inPath); $in.CopyTo($cs); $in.Close(); $cs.FlushFinalBlock(); $cs.Close(); $out.Close()
}
function Unprotect-File($inPath,$outPath,$pw){
    $in = [System.IO.File]::OpenRead($inPath)
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16; $null=$in.Read($salt,0,16); $null=$in.Read($iv,0,16)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw,$salt,200000)
    $aes = [System.Security.Cryptography.Aes]::Create(); $aes.KeySize=256; $aes.Key=$kdf.GetBytes(32); $aes.IV=$iv
    $cs  = New-Object System.Security.Cryptography.CryptoStream($in,$aes.CreateDecryptor(),'Read')
    $out = [System.IO.File]::Open($outPath,'Create'); $cs.CopyTo($out); $out.Close(); $cs.Close(); $in.Close()
}

# Curated AppData map (used by backup AND restore so destinations round-trip exactly).
function Get-AppDataMap {
    @(
        @{ Name='VSCode';          Src="$env:APPDATA\Code\User" }
        @{ Name='VSCode-Insiders'; Src="$env:APPDATA\Code - Insiders\User" }
        @{ Name='Cursor';          Src="$env:APPDATA\Cursor\User" }
        @{ Name='OBS';             Src="$env:APPDATA\obs-studio" }
        @{ Name='Notepad++';       Src="$env:APPDATA\Notepad++" }
        @{ Name='PowerToys';       Src="$env:LOCALAPPDATA\Microsoft\PowerToys" }
        @{ Name='WindowsTerminal'; Src="$env:LOCALAPPDATA\Microsoft\Windows Terminal" }
        @{ Name='AutoHotkey';      Src="$env:APPDATA\AutoHotkey" }
    )
}

function Invoke-ModuleBackup($id,$root){
    $meta  = $sync.Meta[$id]
    $entry = @{ Id=$id; Name=$meta.Name; Cat=$meta.Cat; Secure=[bool]$meta.Sensitive; Size=0; Status='ok'; Note=''; Paths=@() }
    $userHome  = $env:USERPROFILE

    switch($id){
        'apps_winget' {
            $d = Join-Path $root 'apps'; EnsureDir $d
            if(CmdExists 'winget'){ & winget export -o (Join-Path $d 'winget-packages.json') --accept-source-agreements *>$null; WL '   winget list exported.' }
            else { $entry.Status='skip'; $entry.Note='winget not found' }
            $entry.Paths=@('apps'); $entry.Size=FolderSize $d
        }
        'apps_ubundle' {
            $b = Join-Path ([Environment]::GetFolderPath('Desktop')) 'apps.ubundle'
            if(Test-Path -LiteralPath $b){ $d=Join-Path $root 'apps'; EnsureDir $d; Copy-Item $b (Join-Path $d 'apps.ubundle') -Force; $entry.Paths=@('apps') }
            else { $entry.Status='skip'; $entry.Note='no apps.ubundle on Desktop' }
        }
        'dev_vscode' {
            $d = Join-Path $root 'dev'; EnsureDir $d; $any=$false
            foreach($pair in @(@('code','vscode'),@('code-insiders','vscode-insiders'),@('cursor','cursor'))){
                if(CmdExists $pair[0]){ & $pair[0] --list-extensions 2>$null | Set-Content -LiteralPath (Join-Path $d ("{0}-extensions.txt" -f $pair[1])) -Encoding UTF8; $any=$true }
            }
            if(-not $any){ $entry.Status='skip'; $entry.Note='no editors on PATH' } else { $entry.Paths=@('dev') }
        }
        'dev_node' {
            $d = Join-Path $root 'dev'; EnsureDir $d; $any=$false
            if(CmdExists 'npm'){ & npm ls -g --depth=0 --json 2>$null | Set-Content -LiteralPath (Join-Path $d 'npm-globals.json') -Encoding UTF8; $any=$true }
            if(CmdExists 'nvm'){ & nvm list 2>$null | Set-Content -LiteralPath (Join-Path $d 'nvm-versions.txt') -Encoding UTF8; $any=$true }
            if(CmdExists 'fnm'){ & fnm list 2>$null | Set-Content -LiteralPath (Join-Path $d 'fnm-versions.txt') -Encoding UTF8; $any=$true }
            if(-not $any){ $entry.Status='skip'; $entry.Note='node/npm not found' } else { $entry.Paths=@('dev') }
        }
        'dev_python' {
            $d = Join-Path $root 'dev\python'; EnsureDir $d; $any=$false
            if(CmdExists 'py'){
                $paths = & py -0p 2>$null
                foreach($line in $paths){ $exe=($line -replace '^\s*\S+\s+','').Trim(); if($exe -and (Test-Path -LiteralPath $exe)){ $tag=($line.Trim() -replace '[^\w\.\-]','_'); & $exe -m pip freeze 2>$null | Set-Content -LiteralPath (Join-Path $d "pip-$tag.txt") -Encoding UTF8; $any=$true } }
            } elseif(CmdExists 'python'){ & python -m pip freeze 2>$null | Set-Content -LiteralPath (Join-Path $d 'pip.txt') -Encoding UTF8; $any=$true }
            if(-not $any){ $entry.Status='skip'; $entry.Note='python not found' } else { $entry.Paths=@('dev') }
        }
        'dev_rust' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            if(CmdExists 'rustup'){ & rustup toolchain list 2>$null | Set-Content -LiteralPath (Join-Path $d 'rustup-toolchains.txt') -Encoding UTF8; & cargo install --list 2>$null | Set-Content -LiteralPath (Join-Path $d 'cargo-crates.txt') -Encoding UTF8; $entry.Paths=@('dev') }
            else { $entry.Status='skip'; $entry.Note='rustup not found' }
        }
        'dev_dotnet' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            if(CmdExists 'dotnet'){ & dotnet tool list -g 2>$null | Set-Content -LiteralPath (Join-Path $d 'dotnet-tools.txt') -Encoding UTF8; $entry.Paths=@('dev') }
            else { $entry.Status='skip'; $entry.Note='dotnet not found' }
        }
        'dev_git' {
            $d = Join-Path $root 'dev\git'; EnsureDir $d; $any=$false
            foreach($f in @('.gitconfig','.gitignore_global')){ $p=Join-Path $userHome $f; if(Test-Path -LiteralPath $p){ Copy-Item $p (Join-Path $d $f) -Force; $any=$true } }
            $cred=Join-Path $userHome '.git-credentials'
            if(Test-Path -LiteralPath $cred){ Copy-Item $cred (Join-Path $d '.git-credentials') -Force; $entry.Secure=$true }
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
            try{ Get-InstalledModule -ErrorAction SilentlyContinue | Select-Object Name,Version | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $d 'modules.json') -Encoding UTF8 }catch{}
            $entry.Paths=@('dev\powershell')
        }
        'dev_wsl' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            if(CmdExists 'wsl'){ & wsl -l -v 2>$null | Set-Content -LiteralPath (Join-Path $d 'wsl-distros.txt') -Encoding UTF8; $entry.Note='list only'; $entry.Paths=@('dev') }
            else { $entry.Status='skip'; $entry.Note='wsl not found' }
        }
        'dev_env' {
            $d = Join-Path $root 'dev'; EnsureDir $d
            [Environment]::GetEnvironmentVariables('User') | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $d 'env-user.json') -Encoding UTF8
            $entry.Paths=@('dev')
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
        'win_drives' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            try{ Get-SmbMapping -ErrorAction SilentlyContinue | Select-Object LocalPath,RemotePath | Export-Csv (Join-Path $d 'drives.csv') -NoTypeInformation }catch{}
            $entry.Paths=@('windows')
        }
        'win_hosts' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            $h = "$env:WINDIR\System32\drivers\etc\hosts"; if(Test-Path -LiteralPath $h){ Copy-Item $h (Join-Path $d 'hosts') -Force }
            $entry.Paths=@('windows')
        }
        'win_tasks' {
            $d = Join-Path $root 'windows\tasks'; EnsureDir $d; $n=0
            try{ foreach($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft*' -and $_.TaskPath -ne '\' })){ $xml=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath; $safe=($t.TaskName -replace '[^\w\.\-]','_'); $xml | Set-Content -LiteralPath (Join-Path $d "$safe.xml") -Encoding UTF8; $n++ } }catch{}
            if($n -eq 0){ $entry.Status='skip'; $entry.Note='none found' } else { $entry.Paths=@('windows\tasks'); $entry.Note="$n tasks" }
        }
        'win_explorer' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            & reg export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' (Join-Path $d 'explorer-advanced.reg') /y *>$null
            $entry.Paths=@('windows')
        }
        'win_terminal' {
            $d = Join-Path $root 'windows'; EnsureDir $d; $any=$false
            foreach($p in @("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json","$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json")){ if(Test-Path -LiteralPath $p){ Copy-Item $p (Join-Path $d 'terminal-settings.json') -Force; $any=$true; break } }
            if(-not $any){ $entry.Status='skip'; $entry.Note='no settings.json' } else { $entry.Paths=@('windows') }
        }
        'win_printers' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            try{ Get-Printer -ErrorAction SilentlyContinue | Select-Object Name,DriverName,PortName,Shared | Export-Csv (Join-Path $d 'printers.csv') -NoTypeInformation }catch{}
            $entry.Note='list only'; $entry.Paths=@('windows')
        }
        'win_defaultapps' {
            $d = Join-Path $root 'windows'; EnsureDir $d
            try{ & Dism.exe /Online /Export-DefaultAppAssociations:(Join-Path $d 'default-apps.xml') *>$null; if($LASTEXITCODE -ne 0){ $entry.Status='skip'; $entry.Note='needs admin' } else { $entry.Paths=@('windows') } }catch{ $entry.Status='skip'; $entry.Note='needs admin' }
        }
        'win_fonts' {
            $s = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
            if(Test-Path -LiteralPath $s){ $d=Join-Path $root 'windows\fonts'; Robo $s $d $false | Out-Null; $entry.Paths=@('windows\fonts'); $entry.Size=FolderSize $d } else { $entry.Status='skip'; $entry.Note='none' }
        }
        'app_appdata' {
            $base = Join-Path $root 'appdata'; $any=$false
            foreach($app in (Get-AppDataMap)){ if(Test-Path -LiteralPath $app.Src){ Robo $app.Src (Join-Path $base $app.Name) (-not $sync.AppDataFull) | Out-Null; $any=$true } }
            if(-not $any){ $entry.Status='skip'; $entry.Note='no known app configs' } else { $entry.Paths=@('appdata'); $entry.Size=FolderSize $base }
        }
        'app_putty' {
            $d = Join-Path $root 'appdata\putty'; EnsureDir $d
            & reg export 'HKCU\Software\SimonTatham' (Join-Path $d 'putty.reg') /y *>$null
            if($LASTEXITCODE -ne 0){ $entry.Status='skip'; $entry.Note='no PuTTY data' } else { $entry.Paths=@('appdata\putty') }
        }
        default {
            if($id -like 'user_*'){
                $map=@{ user_documents='MyDocuments'; user_desktop='Desktop'; user_pictures='MyPictures'; user_downloads='Downloads'; user_videos='MyVideos'; user_music='MyMusic' }
                $sf=$map[$id]; if($sf -eq 'Downloads'){ $src=Join-Path $userHome 'Downloads' } else { $src=[Environment]::GetFolderPath($sf) }
                if($src -and (Test-Path -LiteralPath $src)){ $d=Join-Path $root ("userfolders\{0}" -f (Split-Path $src -Leaf)); Robo $src $d $false | Out-Null; $entry.Paths=@((RelOf $root $d)); $entry.Size=FolderSize $d }
                else { $entry.Status='skip'; $entry.Note='folder missing' }
            }
        }
    }
    if($entry.Size -eq 0 -and $entry.Paths.Count -gt 0){ $tot=0; foreach($rp in $entry.Paths){ $tot += FolderSize (Join-Path $root $rp) }; $entry.Size=$tot }
    return $entry
}

function Protect-Secure($root,$entries,$pw){
    $stage = Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')); EnsureDir $stage
    foreach($e in $entries){ foreach($rel in $e.Paths){ $full=Join-Path $root $rel; if(Test-Path -LiteralPath $full){ $tp=Join-Path $stage $rel; EnsureDir (Split-Path $tp -Parent); Copy-Item -LiteralPath $full -Destination $tp -Recurse -Force } } }
    $zip = Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')+'.zip')
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
    EnsureDir (Join-Path $root 'secure')
    Protect-File $zip (Join-Path $root 'secure\vault.enc') $pw
    Remove-Item $zip -Force -ErrorAction SilentlyContinue; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    foreach($e in $entries){ foreach($rel in $e.Paths){ $full=Join-Path $root $rel; if(Test-Path -LiteralPath $full){ Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue } } }
}

function Start-BackupRun {
    $dest=$sync.Dest; $ids=@($sync.Ids); $enc=$sync.Encrypt; $pw=$sync.Password
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $root  = Join-Path $dest ("Phoenix-Backup-{0}-{1}" -f $env:COMPUTERNAME,$stamp)
    EnsureDir $root; $sync.OutputPath=$root
    $man = @{ Tool='Phoenix'; Version='1.0'; Machine=$env:COMPUTERNAME; User=$env:USERNAME; Created=(Get-Date).ToString('o'); Encrypted=[bool]$enc; Modules=@() }
    $total=$ids.Count; $i=0; $secure=@()
    foreach($id in $ids){
        if($sync.Cancel){ WL 'Cancelled.' 'Warn'; break }
        $i++; $nm=$sync.Meta[$id].Name; Prog ([int](($i-1)/$total*94)) "Backing up: $nm"; WL "-> $nm"
        try{
            $e = Invoke-ModuleBackup $id $root
            $man.Modules += $e
            if($e.Secure -and $e.Paths.Count -gt 0 -and $e.Status -ne 'skip'){ $secure += $e }
            if($e.Status -eq 'skip'){ WL ("   skipped ({0})" -f $e.Note) 'Warn' } else { WL ("   done  {0}" -f (Fmt-Bytes $e.Size)) 'Ok' }
        }catch{ WL ("   FAILED: {0}" -f $_.Exception.Message) 'Error'; $man.Modules += @{ Id=$id; Name=$nm; Status='error'; Note=$_.Exception.Message; Paths=@() } }
    }
    if($enc -and $secure.Count -gt 0 -and $pw){ Prog 96 'Encrypting sensitive data...'; try{ Protect-Secure $root $secure $pw; $man.Vault='secure/vault.enc'; WL '   sensitive data encrypted to vault.enc' 'Ok' }catch{ WL "Encryption failed: $($_.Exception.Message)" 'Error' } }
    elseif($secure.Count -gt 0){ WL 'NOTE: sensitive data stored UNENCRYPTED (vault was off).' 'Warn' }
    ($man | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding UTF8
    Prog 100 'Backup complete'; WL "Saved to: $root" 'Ok'; $sync.Result='backup'
}

function Invoke-ModuleRestore($id,$src,$vault){
    $meta=$sync.Meta[$id]; $base = if($meta.Sensitive -and $vault){ $vault } else { $src }
    $userHome=$env:USERPROFILE
    switch($id){
        'apps_winget' { $f=Join-Path $src 'apps\winget-packages.json'; if((Test-Path -LiteralPath $f) -and (CmdExists 'winget')){ WL '   importing apps (this can take a while)...'; & winget import -i $f --accept-package-agreements --accept-source-agreements --ignore-unavailable --ignore-versions *>$null } }
        'dev_vscode'  { foreach($pair in @(@('code','vscode'),@('code-insiders','vscode-insiders'),@('cursor','cursor'))){ $f=Join-Path $src ("dev\{0}-extensions.txt" -f $pair[1]); if((Test-Path -LiteralPath $f) -and (CmdExists $pair[0])){ foreach($ext in (Get-Content $f)){ if($ext.Trim()){ & $pair[0] --install-extension $ext.Trim() --force *>$null } } } } }
        'dev_node'    { $f=Join-Path $src 'dev\npm-globals.json'; if((Test-Path -LiteralPath $f) -and (CmdExists 'npm')){ try{ $j=Get-Content $f -Raw | ConvertFrom-Json; if($j.dependencies){ foreach($p in $j.dependencies.PSObject.Properties.Name){ if($p -ne 'npm'){ & npm i -g $p *>$null } } } }catch{} } }
        'dev_rust'    { $f=Join-Path $src 'dev\cargo-crates.txt'; if((Test-Path -LiteralPath $f) -and (CmdExists 'cargo')){ foreach($line in (Get-Content $f)){ if($line -match '^(\S+)\s+v'){ & cargo install $Matches[1] *>$null } } } }
        'dev_dotnet'  { $f=Join-Path $src 'dev\dotnet-tools.txt'; if((Test-Path -LiteralPath $f) -and (CmdExists 'dotnet')){ foreach($line in (Get-Content $f | Select-Object -Skip 2)){ $c=($line -split '\s+')[0]; if($c){ & dotnet tool install -g $c *>$null } } } }
        'dev_git'     { $g=Join-Path $base 'dev\git'; if(Test-Path -LiteralPath $g){ foreach($f in (Get-ChildItem -LiteralPath $g -File)){ Copy-Item $f.FullName (Join-Path $userHome $f.Name) -Force } } }
        'dev_ssh'     { $s=Join-Path $base 'dev\ssh'; if(Test-Path -LiteralPath $s){ Robo $s (Join-Path $userHome '.ssh') $false | Out-Null } }
        'dev_ps'      { $p=Join-Path $src 'dev\powershell\profile.ps1'; if((Test-Path -LiteralPath $p) -and $PROFILE){ EnsureDir (Split-Path $PROFILE -Parent); Copy-Item $p $PROFILE -Force } }
        'dev_env'     { $f=Join-Path $src 'dev\env-user.json'; if(Test-Path -LiteralPath $f){ try{ $j=Get-Content $f -Raw | ConvertFrom-Json; foreach($k in $j.PSObject.Properties.Name){ if($k -eq 'Path'){ $cur=[Environment]::GetEnvironmentVariable('Path','User'); $merged=(@($cur -split ';') + @($j.$k -split ';') | Where-Object { $_ } | Select-Object -Unique) -join ';'; [Environment]::SetEnvironmentVariable('Path',$merged,'User') } else { [Environment]::SetEnvironmentVariable($k,$j.$k,'User') } } }catch{} } }
        'win_wifi'    { $d=Join-Path $base 'windows\wifi'; if(Test-Path -LiteralPath $d){ foreach($x in (Get-ChildItem -LiteralPath $d -Filter *.xml)){ & netsh wlan add profile filename="$($x.FullName)" user=all *>$null } } }
        'win_power'   { $d=Join-Path $src 'windows\power'; if(Test-Path -LiteralPath $d){ foreach($x in (Get-ChildItem -LiteralPath $d -Filter *.pow)){ & powercfg /import $x.FullName *>$null } } }
        'win_hosts'   { $f=Join-Path $src 'windows\hosts'; if(Test-Path -LiteralPath $f){ Copy-Item $f "$env:WINDIR\System32\drivers\etc\hosts" -Force -ErrorAction SilentlyContinue } }
        'win_tasks'   { $d=Join-Path $src 'windows\tasks'; if(Test-Path -LiteralPath $d){ foreach($x in (Get-ChildItem -LiteralPath $d -Filter *.xml)){ try{ Register-ScheduledTask -Xml (Get-Content $x.FullName -Raw) -TaskName ([IO.Path]::GetFileNameWithoutExtension($x.Name)) -Force *>$null }catch{} } } }
        'win_explorer'{ $f=Join-Path $src 'windows\explorer-advanced.reg'; if(Test-Path -LiteralPath $f){ & reg import $f *>$null } }
        'win_terminal'{ $f=Join-Path $src 'windows\terminal-settings.json'; if(Test-Path -LiteralPath $f){ $t="$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"; if(Test-Path -LiteralPath $t){ Copy-Item $f (Join-Path $t 'settings.json') -Force } } }
        'win_defaultapps'{ $f=Join-Path $src 'windows\default-apps.xml'; if(Test-Path -LiteralPath $f){ try{ & Dism.exe /Online /Import-DefaultAppAssociations:$f *>$null }catch{} } }
        'win_fonts'   { $d=Join-Path $src 'windows\fonts'; if(Test-Path -LiteralPath $d){ Robo $d "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" $false | Out-Null; WL '   fonts copied (may need re-install to register).' 'Warn' } }
        'app_appdata' { foreach($app in (Get-AppDataMap)){ $s=Join-Path $src ("appdata\{0}" -f $app.Name); if(Test-Path -LiteralPath $s){ EnsureDir $app.Src; Robo $s $app.Src $false | Out-Null } } }
        'app_putty'   { $f=Join-Path $base 'appdata\putty\putty.reg'; if(Test-Path -LiteralPath $f){ & reg import $f *>$null } }
        'apps_ubundle'{ WL '   apps.ubundle is in the backup - open it in UniGetUI to install.' 'Info' }
        'dev_wsl'     { WL '   WSL distros are list-only; reinstall from Store/wsl --install.' 'Info' }
        'win_drives'  { WL '   mapped drives are list-only (see drives.csv).' 'Info' }
        'win_printers'{ WL '   printers are list-only (see printers.csv).' 'Info' }
        default {
            if($id -like 'user_*'){ $d=Join-Path $src ("userfolders") ; if(Test-Path -LiteralPath $d){ $leafMap=@{ user_documents='Documents'; user_desktop='Desktop'; user_pictures='Pictures'; user_downloads='Downloads'; user_videos='Videos'; user_music='Music' }; $leaf=$leafMap[$id]; $sp=Join-Path $d $leaf; if(Test-Path -LiteralPath $sp){ Robo $sp (Join-Path $userHome $leaf) $false | Out-Null } } }
        }
    }
}

function Start-RestoreRun {
    $src=$sync.RestoreSrc; $ids=@($sync.Ids); $pw=$sync.Password
    $manFile=Join-Path $src 'manifest.json'; if(-not (Test-Path -LiteralPath $manFile)){ WL 'manifest.json not found.' 'Error'; $sync.Result='error'; return }
    $man=Get-Content $manFile -Raw | ConvertFrom-Json
    $needsRp = @($ids | Where-Object { $_ -like 'win_*' -or $_ -eq 'app_putty' }).Count -gt 0
    if($needsRp){ Prog 3 'Creating system restore point...'; try{ Checkpoint-Computer -Description 'Phoenix restore' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop; WL '   restore point created.' 'Ok' }catch{ WL '   restore point skipped (needs admin / may be throttled).' 'Warn' } }
    $vault=$null
    $needsVault = $man.Vault -and (@($ids | Where-Object { $sync.Meta[$_].Sensitive }).Count -gt 0)
    if($needsVault){
        if(-not $pw){ WL 'Vault password required for sensitive items.' 'Error'; $sync.Result='error'; return }
        Prog 6 'Decrypting vault...'
        try{ $zip=Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')+'.zip'); Unprotect-File (Join-Path $src 'secure\vault.enc') $zip $pw; $vault=Join-Path $env:TEMP ('phx_'+[Guid]::NewGuid().ToString('N')); EnsureDir $vault; [System.IO.Compression.ZipFile]::ExtractToDirectory($zip,$vault); Remove-Item $zip -Force; WL '   vault decrypted.' 'Ok' }
        catch{ WL 'Decryption failed - wrong password?' 'Error'; $sync.Result='error'; return }
    }
    $total=$ids.Count; $i=0
    foreach($id in $ids){
        if($sync.Cancel){ WL 'Cancelled.' 'Warn'; break }
        $i++; $nm=$sync.Meta[$id].Name; Prog ([int](6 + ($i-1)/$total*90)) "Restoring: $nm"; WL "-> $nm"
        try{ Invoke-ModuleRestore $id $src $vault; WL '   done' 'Ok' }catch{ WL ("   FAILED: {0}" -f $_.Exception.Message) 'Error' }
    }
    if($vault -and (Test-Path -LiteralPath $vault)){ Remove-Item $vault -Recurse -Force -ErrorAction SilentlyContinue }
    Prog 100 'Restore complete'; WL 'Some changes need a sign-out/restart to appear.' 'Warn'; $sync.Result='restore'
}

function Get-Estimate($id){
    $userHome=$env:USERPROFILE
    switch($id){
        'dev_ssh'        { FolderSize (Join-Path $userHome '.ssh') }
        'win_fonts'      { FolderSize "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" }
        'app_appdata'    { $t=0; foreach($p in @("$env:APPDATA\Code\User","$env:APPDATA\Cursor\User","$env:APPDATA\obs-studio","$env:APPDATA\Notepad++","$env:LOCALAPPDATA\Microsoft\PowerToys")){ $t+=FolderSize $p }; $t }
        'user_documents' { FolderSize ([Environment]::GetFolderPath('MyDocuments')) }
        'user_desktop'   { FolderSize ([Environment]::GetFolderPath('Desktop')) }
        'user_pictures'  { FolderSize ([Environment]::GetFolderPath('MyPictures')) }
        'user_downloads' { FolderSize (Join-Path $userHome 'Downloads') }
        'user_videos'    { FolderSize ([Environment]::GetFolderPath('MyVideos')) }
        'user_music'     { FolderSize ([Environment]::GetFolderPath('MyMusic')) }
        default          { 51200 }
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

try{
    switch($sync.Op){
        'Backup'   { Start-BackupRun }
        'Restore'  { Start-RestoreRun }
        'Estimate' { Start-EstimateRun }
    }
}catch{ WL $_.Exception.Message 'Error' }
finally{ Emit 'Done' @{} }
'@
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
              <TextBlock Text="v1.0 - local &amp; offline" Foreground="{StaticResource Muted}" FontSize="11" Margin="6,0"/>
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
                <Button x:Name="BtnStartRestore" Grid.Column="2" Style="{StaticResource Primary}" Width="180" IsEnabled="False"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE7B8;" FontSize="14"/><TextBlock Text="Start restore" Margin="8,0,0,0"/></StackPanel></Button>
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
                    <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Text="- AES-256 encrypted vault for SSH keys, Wi-Fi passwords &amp; PuTTY sessions"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- manifest.json with sizes &amp; status for every item"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Smart AppData mode skips caches (Full mode optional)"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Creates a System Restore Point before restoring Windows settings"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Reinstalls apps, editor extensions, npm/cargo/dotnet globals automatically"/>
                    <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="- Presets (Minimal / Developer / Everything) + live size estimate"/>
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
            <Border Background="{StaticResource Bg1}" CornerRadius="14" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Width="620" Height="440" VerticalAlignment="Center" HorizontalAlignment="Center">
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
                  <TextBox x:Name="OvLog" Background="Transparent" BorderThickness="0" Foreground="{StaticResource Txt}" FontFamily="Cascadia Mono, Consolas" FontSize="12" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="12" VerticalContentAlignment="Top"/>
                </Border>
                <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                  <Button x:Name="BtnOpenFolder" Style="{StaticResource Ghost}" Margin="0,0,10,0" Visibility="Collapsed"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8B7;" FontSize="13"/><TextBlock Text="Open folder" Margin="6,0,0,0"/></StackPanel></Button>
                  <Button x:Name="BtnCancelOp" Style="{StaticResource Ghost}" Width="100"><TextBlock Text="Cancel"/></Button>
                  <Button x:Name="BtnCloseOv" Style="{StaticResource Primary}" Width="100" Visibility="Collapsed"><TextBlock Text="Done"/></Button>
                </StackPanel>
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

    return @{ Row=$row; Check=$cb; Size=$size }
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
            'EstimateDone' { Update-BackupTotal }
            'Done' {
                $Script:Timer.Stop()
                (C 'BtnCancelOp').Visibility='Collapsed'; (C 'BtnCloseOv').Visibility='Visible'
                if($Script:sync.Result -eq 'backup' -and $Script:sync.OutputPath){ (C 'BtnOpenFolder').Visibility='Visible'; $Script:LastOutput=$Script:sync.OutputPath }
                if($Script:sync.Op -eq 'Estimate'){ (C 'Overlay').Visibility='Collapsed' }
                else { (C 'OvTitle').Text = if($Script:sync.Result -eq 'error'){'Finished with errors'} else {'All done'} }
                if($Script:PSInstance){ try{ $Script:PSInstance.EndInvoke($Script:PSHandle) }catch{}; $Script:PSInstance.Dispose(); $Script:PSInstance=$null }
                if($Script:RS){ $Script:RS.Close(); $Script:RS=$null }
            }
        }
    }
})

function Start-Worker($op){
    $Script:sync.Op=$op; $Script:sync.Cancel=$false; $Script:sync.Result=$null; $Script:sync.OutputPath=$null
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
    try{ Start-Process (Join-Path $PSScriptRoot 'Phoenix.cmd') -Verb RunAs; $window.Close() }catch{}
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
    if($dlg.ShowDialog() -eq 'OK'){ $Script:Dest=$dlg.SelectedPath; (C 'TxtDest').Text=$dlg.SelectedPath; (C 'TxtDest').Foreground=$window.FindResource('Txt') }
})

(C 'BtnEstimate').Add_Click({
    $ids=Get-CheckedIds; if($ids.Count -eq 0){ return }
    $Script:sync.Ids=$ids
    (C 'Overlay').Visibility='Visible'; (C 'OvTitle').Text='Estimating size...'; (C 'OvLog').Text=''
    (C 'BtnCancelOp').Visibility='Visible'; (C 'BtnCloseOv').Visibility='Collapsed'; (C 'BtnOpenFolder').Visibility='Collapsed'
    Start-Worker 'Estimate'
})

(C 'BtnStartBackup').Add_Click({
    $ids=Get-CheckedIds
    if($ids.Count -eq 0){ [System.Windows.MessageBox]::Show('Select at least one item.','Phoenix') | Out-Null; return }
    if(-not $Script:Dest){ [System.Windows.MessageBox]::Show('Choose a destination folder first.','Phoenix') | Out-Null; return }
    if((C 'ChkEncrypt').IsChecked -and -not (C 'PwdBox').Password){ [System.Windows.MessageBox]::Show('Enter a vault password or turn off encryption.','Phoenix') | Out-Null; return }
    $Script:sync.Ids=$ids; $Script:sync.Dest=$Script:Dest
    $Script:sync.Encrypt=[bool](C 'ChkEncrypt').IsChecked; $Script:sync.Password=(C 'PwdBox').Password
    $Script:sync.AppDataFull=[bool](C 'ChkAppFull').IsChecked
    (C 'Overlay').Visibility='Visible'; (C 'OvTitle').Text='Backing up...'; (C 'OvLog').Text=''
    (C 'BtnCancelOp').Visibility='Visible'; (C 'BtnCloseOv').Visibility='Collapsed'; (C 'BtnOpenFolder').Visibility='Collapsed'
    Start-Worker 'Backup'
})

(C 'BtnCancelOp').Add_Click({ $Script:sync.Cancel=$true; (C 'OvStatus').Text='Cancelling...' })
(C 'BtnCloseOv').Add_Click({ (C 'Overlay').Visibility='Collapsed' })
(C 'BtnOpenFolder').Add_Click({ if($Script:LastOutput){ Start-Process explorer.exe $Script:LastOutput } })

# ---- Restore side ----
function Load-Manifest($folder){
    $mf = Join-Path $folder 'manifest.json'
    if(-not (Test-Path -LiteralPath $mf)){ [System.Windows.MessageBox]::Show('No manifest.json in that folder. Pick a Phoenix-Backup-... folder.','Phoenix') | Out-Null; return }
    $man = Get-Content $mf -Raw | ConvertFrom-Json
    $Script:Src=$folder; (C 'TxtSrc').Text=$folder; (C 'TxtSrc').Foreground=$window.FindResource('Txt')
    (C 'LblManifestInfo').Text = ("From {0}  -  {1}  -  {2} items{3}" -f $man.Machine, ([datetime]$man.Created).ToString('g'), @($man.Modules).Count, $(if($man.Encrypted){'  -  encrypted vault'}else{''}))

    $panel=C 'PanelRestoreModules'; $panel.Children.Clear(); $Script:RestoreChecks.Clear()
    $hasVault = [bool]$man.Vault
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
    if($hasVault){ (C 'PwRestoreWrap').Visibility='Visible'; (C 'LblVaultHint').Text='Vault password needed for sensitive items' }
    else { (C 'PwRestoreWrap').Visibility='Collapsed'; (C 'LblVaultHint').Text='' }
    $Script:ManifestHasVault=$hasVault
}

(C 'BtnBrowseSrc').Add_Click({
    $dlg=New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description='Open a Phoenix backup folder'
    if($dlg.ShowDialog() -eq 'OK'){ Load-Manifest $dlg.SelectedPath }
})

(C 'BtnStartRestore').Add_Click({
    $ids=@(); foreach($k in $Script:RestoreChecks.Keys){ if($Script:RestoreChecks[$k].IsChecked){ $ids+=$k } }
    if($ids.Count -eq 0){ [System.Windows.MessageBox]::Show('Select at least one item.','Phoenix') | Out-Null; return }
    $needVault = $false; foreach($id in $ids){ if($Script:ModuleById[$id].Sensitive){ $needVault=$true } }
    if($Script:ManifestHasVault -and $needVault -and -not (C 'PwdRestore').Password){ [System.Windows.MessageBox]::Show('Enter the vault password.','Phoenix') | Out-Null; return }
    $msg="This will write files and settings to this PC. Continue?"
    if([System.Windows.MessageBox]::Show($msg,'Confirm restore','YesNo','Warning') -ne 'Yes'){ return }
    $Script:sync.Ids=$ids; $Script:sync.RestoreSrc=$Script:Src; $Script:sync.Password=(C 'PwdRestore').Password
    (C 'Overlay').Visibility='Visible'; (C 'OvTitle').Text='Restoring...'; (C 'OvLog').Text=''
    (C 'BtnCancelOp').Visibility='Visible'; (C 'BtnCloseOv').Visibility='Collapsed'; (C 'BtnOpenFolder').Visibility='Collapsed'
    Start-Worker 'Restore'
})
#endregion

#region ------------------------------------------------------------ Init & show
Build-BackupTree
Apply-Preset 'Developer'
(C 'CmbPreset').SelectedIndex = 1
$window.Add_Closing({ try{ $Script:sync.Cancel=$true; if($Script:Timer){$Script:Timer.Stop()}; if($Script:PSInstance){$Script:PSInstance.Dispose()}; if($Script:RS){$Script:RS.Close()} }catch{} })
$window.ShowDialog() | Out-Null
#endregion
