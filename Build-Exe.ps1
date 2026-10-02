<#
    Build-Exe.ps1 - packs Phoenix.ps1 into a single portable Phoenix.exe.

    No toolchain to install: uses the C# compiler that ships with the .NET Framework on every Windows 10/11.
    The exe embeds Phoenix.ps1, extracts it to %LOCALAPPDATA%\Phoenix\app\<hash>\ on first run, and launches
    Windows PowerShell 5.1 in STA mode with no console window. All arguments are forwarded (so -Headless works).

    Usage:  .\Build-Exe.ps1 [-OutDir dist]
#>
[CmdletBinding()] param([string]$OutDir)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if(-not $OutDir){ $OutDir = Join-Path $here 'dist' }

$ps1 = Join-Path $here 'Phoenix.ps1'
if(-not (Test-Path -LiteralPath $ps1)){ throw "Phoenix.ps1 not found next to this script." }
$version = if((Get-Content -LiteralPath $ps1 -Raw) -match "Tool='Phoenix';\s*Version='([\d\.]+)'"){ $Matches[1] } else { '1.0' }
$ver4 = (($version -split '\.') + @('0','0','0'))[0..3] -join '.'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $csc)){ $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if(-not (Test-Path -LiteralPath $csc)){ throw ".NET Framework 4.x C# compiler not found (csc.exe)." }

$work = Join-Path $env:TEMP ('phx_build_'+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $work | Out-Null
try{
    # Icon: orange flame-ish rounded square with a white "P". Good enough to be recognisable in the taskbar.
    $ico = Join-Path $work 'phoenix.ico'
    try{
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap 64,64
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='AntiAliasGridFit'
        $g.Clear([System.Drawing.Color]::Transparent)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r=14; $path.AddArc(0,0,$r,$r,180,90); $path.AddArc(64-$r,0,$r,$r,270,90); $path.AddArc(64-$r,64-$r,$r,$r,0,90); $path.AddArc(0,64-$r,$r,$r,90,90); $path.CloseFigure()
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.Point]::new(0,0)),([System.Drawing.Point]::new(64,64)),([System.Drawing.Color]::FromArgb(255,249,115,22)),([System.Drawing.Color]::FromArgb(255,220,38,38))
        $g.FillPath($brush,$path)
        $font = New-Object System.Drawing.Font 'Segoe UI',34,([System.Drawing.FontStyle]::Bold),([System.Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object System.Drawing.StringFormat; $sf.Alignment='Center'; $sf.LineAlignment='Center'
        $g.DrawString('P',$font,[System.Drawing.Brushes]::White,(New-Object System.Drawing.RectangleF 0,-2,64,64),$sf)
        $g.Dispose()
        $hicon = $bmp.GetHicon(); $icon = [System.Drawing.Icon]::FromHandle($hicon)
        $fs = [IO.File]::Open($ico,'Create'); $icon.Save($fs); $fs.Close()
        $bmp.Dispose()
    }catch{ Write-Warning "Icon generation failed ($($_.Exception.Message)) - building without an icon."; $ico=$null }

    $manifest = Join-Path $work 'app.manifest'
    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="$ver4" name="Phoenix.WindowsMigrationKit" type="win32"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2"><security><requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
    <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
  </requestedPrivileges></security></trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
    <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
  </windowsSettings></application>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
  </application></compatibility>
</assembly>
"@ | Set-Content -LiteralPath $manifest -Encoding UTF8

    # C# 5 only (the framework csc) - no string interpolation, no ?. operator.
    $cs = Join-Path $work 'Phoenix.cs'
    @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Phoenix - Windows Migration Kit")]
[assembly: AssemblyDescription("Back up everything that matters, wipe Windows without fear, and rise again on a fresh install.")]
[assembly: AssemblyProduct("Phoenix")]
[assembly: AssemblyCompany("Abdelaziz Ali")]
[assembly: AssemblyCopyright("MIT License - (c) 2026 Abdelaziz Ali")]
[assembly: AssemblyVersion("$ver4")]
[assembly: AssemblyFileVersion("$ver4")]

static class Program
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(int dwProcessId);
    const int ATTACH_PARENT_PROCESS = -1;

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            byte[] script = ReadResource("Phoenix.ps1");
            string hash;
            using (SHA256 sha = SHA256.Create()) { hash = BitConverter.ToString(sha.ComputeHash(script)).Replace("-", "").Substring(0, 12).ToLowerInvariant(); }

            string appRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Phoenix", "app");
            string dir = Path.Combine(appRoot, hash);
            string ps1 = Path.Combine(dir, "Phoenix.ps1");
            if (!File.Exists(ps1))
            {
                Directory.CreateDirectory(dir);
                File.WriteAllBytes(ps1, script);
                // Drop builds from older versions so the folder does not grow forever.
                foreach (string old in Directory.GetDirectories(appRoot))
                    if (!string.Equals(old, dir, StringComparison.OrdinalIgnoreCase)) { try { Directory.Delete(old, true); } catch { } }
            }

            string psExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(psExe)) throw new FileNotFoundException("Windows PowerShell 5.1 was not found.", psExe);

            bool headless = false;
            foreach (string a in args) if (string.Equals(a, "-Headless", StringComparison.OrdinalIgnoreCase)) headless = true;
            // In -Headless mode reuse the caller's console (if any) so logs are visible; otherwise never show one.
            bool haveConsole = headless && AttachConsole(ATTACH_PARENT_PROCESS);

            ProcessStartInfo psi = new ProcessStartInfo(psExe);
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + ps1 + "\"" + Quote(args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = !haveConsole;
            psi.WorkingDirectory = dir;
            psi.EnvironmentVariables["PHOENIX_EXE"] = Assembly.GetExecutingAssembly().Location;

            using (Process p = Process.Start(psi)) { p.WaitForExit(); return p.ExitCode; }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Phoenix could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static byte[] ReadResource(string name)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (s == null) throw new InvalidOperationException("Embedded resource missing: " + name);
            using (MemoryStream ms = new MemoryStream()) { s.CopyTo(ms); return ms.ToArray(); }
        }
    }

    static string Quote(string[] args)
    {
        StringBuilder sb = new StringBuilder();
        foreach (string a in args)
        {
            sb.Append(' ');
            if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '"', '\t' }) < 0) { sb.Append(a); continue; }
            sb.Append('"').Append(a.Replace("\\", "\\\\").Replace("\"", "\\\"")).Append('"');
        }
        return sb.ToString();
    }
}
"@ | Set-Content -LiteralPath $cs -Encoding UTF8

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $exe = Join-Path $OutDir 'Phoenix.exe'
    $cscArgs = @('/nologo','/target:winexe','/optimize+','/platform:anycpu',"/out:$exe","/resource:$ps1,Phoenix.ps1","/win32manifest:$manifest",'/r:System.Windows.Forms.dll',$cs)
    if($ico){ $cscArgs += "/win32icon:$ico" }
    $out = & $csc @cscArgs 2>&1
    if($LASTEXITCODE -ne 0){ $out | ForEach-Object { Write-Host $_ }; throw "csc.exe failed with exit code $LASTEXITCODE" }
    $fi = Get-Item -LiteralPath $exe
    Write-Host ("Built {0}  ({1:N0} KB, v{2})" -f $fi.FullName,($fi.Length/1KB),$version)
    Write-Host ("SHA256 {0}" -f (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower())
}
finally{ Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
