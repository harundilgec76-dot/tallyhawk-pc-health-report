<#
.SYNOPSIS
    TallyHawk PC Health Report (free edition) - one-file, read-only health check for a Windows PC.

.DESCRIPTION
    Checks disk space and disk health, antivirus, firewall, BitLocker, pending reboot, last update,
    uptime, Windows activation and Windows 11 readiness basics, then writes a clean HTML report
    with a 0-100 health score. Nothing on the computer is changed.

    Part of the TallyHawk project. The full TallyHawk kit adds fleet-wide dashboards,
    software & warranty inventory, one-click fixes with rollback, and scheduled scans.

.PARAMETER OutputPath
    Folder for the HTML report. Default: your Desktop.
.PARAMETER NoOpen
    Do not open the report in the browser when finished.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Get-PCHealthReport.ps1

.NOTES
    License: MIT. Works on Windows PowerShell 5.1 and PowerShell 7+.
    Run as administrator for BitLocker, TPM and Secure Boot results.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = [Environment]::GetFolderPath('Desktop'),
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
$ProUrl = 'https://dilgec.gumroad.com/l/tallyhawk'

function Try-Get { param([scriptblock]$Script, $Default = $null) try { & $Script } catch { $Default } }
function Fmt { param([string]$F, [object[]]$V) [string]::Format([Globalization.CultureInfo]::InvariantCulture, $F, $V) }   # dot decimals on every Windows language
function Enc { param($s) if ($null -eq $s) { return '' } [System.Net.WebUtility]::HtmlEncode([string]$s) }

$isAdmin = Try-Get { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } $false
Write-Host ''
Write-Host '  TallyHawk PC Health Report (free)' -ForegroundColor Yellow
if (-not $isAdmin) { Write-Host '  Tip: run as administrator for BitLocker, TPM and Secure Boot checks.' -ForegroundColor DarkYellow }
Write-Host '  Collecting (read-only)...' -ForegroundColor Gray

$os   = Try-Get { Get-CimInstance Win32_OperatingSystem }
$cs   = Try-Get { Get-CimInstance Win32_ComputerSystem }
$bios = Try-Get { Get-CimInstance Win32_BIOS }
$cpu  = Try-Get { Get-CimInstance Win32_Processor | Select-Object -First 1 }
$cv   = Try-Get { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
$vols = @(Try-Get { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' } @())
$pd   = @(Try-Get { Get-PhysicalDisk } @())
$mp   = Try-Get { Get-MpComputerStatus }
$av   = @(Try-Get { Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct } @())
$fw   = @(Try-Get { Get-NetFirewallProfile } @())
$bl   = if ($isAdmin) { Try-Get { Get-BitLockerVolume -MountPoint $env:SystemDrive } } else { $null }
$tpm  = if ($isAdmin) { Try-Get { Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm } } else { $null }
$sb   = if ($isAdmin) { Try-Get { [bool](Confirm-SecureBootUEFI) } } else { $null }
$lic  = Try-Get { Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1 }
$hf   = Try-Get { Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1 }

# Self-built PCs report placeholders; fall back to the motherboard identity.
$ph = '^(To be filled.*|Default string|System Serial Number|System Product Name|System manufacturer|Not Applicable|0+|None|\s*)$'
$mfr = [string]$cs.Manufacturer; $model = [string]$cs.Model; $serial = ([string]$bios.SerialNumber).Trim()
if ($serial -match $ph -or $model -match $ph -or $mfr -match $ph) {
    $bb = Try-Get { Get-CimInstance Win32_BaseBoard | Select-Object -First 1 }
    if ($bb) {
        if ($serial -match $ph -and ([string]$bb.SerialNumber).Trim() -notmatch $ph) { $serial = ([string]$bb.SerialNumber).Trim() }
        if ($model -match $ph -and $bb.Product) { $model = '{0} (motherboard)' -f $bb.Product }
        if ($mfr -match $ph -and $bb.Manufacturer) { $mfr = $bb.Manufacturer }
    }
}
if ($serial -match $ph) { $serial = 'not reported by firmware' }

$pending = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'Component Based Servicing' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }

$build = if ($os) { [int]$os.BuildNumber } else { 0 }
$caption = if ($os) { $os.Caption } else { 'Unknown' }
if ($build -ge 22000) { $caption = $caption -replace 'Windows 10', 'Windows 11' }
$uptime = if ($os) { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) } else { $null }

# ---------- checks ----------
$checks = New-Object System.Collections.Generic.List[object]
function Add-Check { param($Area, $Name, $State, $Detail) $checks.Add([pscustomobject]@{ Area = $Area; Name = $Name; State = $State; Detail = $Detail }) }

foreach ($v in $vols) {
    if (-not $v.Size) { continue }
    $pct = [math]::Round($v.FreeSpace / $v.Size * 100, 1)
    $st = if ($pct -lt 8) { 'Critical' } elseif ($pct -lt 15) { 'Warning' } else { 'OK' }
    Add-Check 'Storage' ('Free space on {0}' -f $v.DeviceID) $st (Fmt '{0} GB free of {1} GB ({2}%)' @([math]::Round($v.FreeSpace / 1GB, 1), [math]::Round($v.Size / 1GB, 1), $pct))
}
foreach ($d in $pd) {
    $st = if ([string]$d.HealthStatus -eq 'Healthy') { 'OK' } else { 'Critical' }
    Add-Check 'Storage' ('Disk health: {0}' -f $d.FriendlyName) $st ('{0} {1}, {2} GB, status {3}' -f $d.MediaType, $d.BusType, [math]::Round($d.Size / 1GB), $d.HealthStatus)
}

$thirdParty = @($av | Where-Object { $_.displayName -notmatch 'Defender' -and ('{0:X6}' -f [int]$_.productState).Substring(2, 2) -match '1[01]' })
if ($mp) {
    $st = if ($mp.RealTimeProtectionEnabled) { 'OK' } elseif ($thirdParty.Count) { 'OK' } else { 'Critical' }
    $det = if ($mp.RealTimeProtectionEnabled) { 'Microsoft Defender real-time protection is on' } elseif ($thirdParty.Count) { 'Protected by ' + (($thirdParty | ForEach-Object { $_.displayName }) -join ', ') } else { 'Real-time protection is OFF and no other antivirus is active' }
    Add-Check 'Security' 'Antivirus' $st $det
    if ($mp.RealTimeProtectionEnabled) {
        $st = if ($mp.AntivirusSignatureAge -gt 7) { 'Warning' } else { 'OK' }
        Add-Check 'Security' 'Antivirus definitions' $st ('{0} day(s) old' -f $mp.AntivirusSignatureAge)
    }
}
elseif ($thirdParty.Count) { Add-Check 'Security' 'Antivirus' 'OK' ('Protected by ' + (($thirdParty | ForEach-Object { $_.displayName }) -join ', ')) }
else { Add-Check 'Security' 'Antivirus' 'Unknown' 'Antivirus status could not be read' }

if ($fw.Count) {
    $off = @($fw | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    if ($off.Count) { Add-Check 'Security' 'Windows Firewall' 'Critical' ('Disabled profiles: ' + ($off -join ', ')) }
    else { Add-Check 'Security' 'Windows Firewall' 'OK' 'All profiles enabled' }
}
if ($bl) {
    $on = ([string]$bl.ProtectionStatus -eq 'On')
    if ($on) { Add-Check 'Security' 'BitLocker (system drive)' 'OK' (Fmt 'Encrypted ({0}%)' @($bl.EncryptionPercentage)) }
    elseif ([int]$bl.EncryptionPercentage -ge 100) { Add-Check 'Security' 'BitLocker (system drive)' 'Warning' 'Encrypted, but protection is suspended - data is readable. Resume protection with: manage-bde -protectors -enable C:' }
    else { Add-Check 'Security' 'BitLocker (system drive)' 'Warning' 'Not encrypted' }
}
else { Add-Check 'Security' 'BitLocker (system drive)' 'Unknown' 'Run as administrator to check' }
$smb1 = Try-Get { [bool](Get-SmbServerConfiguration).EnableSMB1Protocol }
if ($null -ne $smb1) { Add-Check 'Security' 'SMBv1 protocol' $(if ($smb1) { 'Critical' } else { 'OK' }) $(if ($smb1) { 'Enabled - obsolete and dangerous' } else { 'Disabled' }) }
$uac = Try-Get { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA }
if ($null -ne $uac) { Add-Check 'Security' 'User Account Control' $(if ($uac -eq 1) { 'OK' } else { 'Critical' }) $(if ($uac -eq 1) { 'Enabled' } else { 'Disabled' }) }

if ($pending.Count) { Add-Check 'Updates' 'Pending restart' 'Warning' ('Restart required: ' + ($pending -join ', ')) } else { Add-Check 'Updates' 'Pending restart' 'OK' 'No restart pending' }
if ($hf) {
    $age = [int]((Get-Date) - $hf.InstalledOn).TotalDays
    Add-Check 'Updates' 'Last installed update' $(if ($age -gt 45) { 'Warning' } else { 'OK' }) ('{0} on {1} ({2} days ago)' -f $hf.HotFixID, $hf.InstalledOn.ToString('yyyy-MM-dd'), $age)
}
if ($null -ne $uptime) { Add-Check 'Updates' 'Uptime' $(if ($uptime -gt 14) { 'Info' } else { 'OK' }) (Fmt '{0} days since last restart' @($uptime)) }
if ($lic) { Add-Check 'Licensing' 'Windows activation' $(if ($lic.LicenseStatus -eq 1) { 'OK' } else { 'Warning' }) $(if ($lic.LicenseStatus -eq 1) { 'Activated (' + $lic.ProductKeyChannel + ')' } else { 'Not activated (status ' + $lic.LicenseStatus + ')' }) }
if ($build -lt 22000 -and $build -gt 0) { Add-Check 'Lifecycle' 'Operating system support' 'Critical' 'Windows 10 reached end of support on 2025-10-14 (only ESU-enrolled devices still get patches)' }
if ($tpm) { Add-Check 'Lifecycle' 'TPM' $(if (($tpm.SpecVersion -split ',')[0] -ge '2.0') { 'OK' } else { 'Warning' }) ('Version ' + ($tpm.SpecVersion -split ',')[0]) }
if ($null -ne $sb) { Add-Check 'Lifecycle' 'Secure Boot' $(if ($sb) { 'OK' } else { 'Warning' }) $(if ($sb) { 'Enabled' } else { 'Disabled' }) }

$score = 100
foreach ($c in $checks) { switch ($c.State) { 'Critical' { $score -= 20 } 'Warning' { $score -= 7 } 'Info' { $score -= 1 } } }
if ($score -lt 0) { $score = 0 }
$grade = if ($score -ge 90) { 'A' } elseif ($score -ge 75) { 'B' } elseif ($score -ge 60) { 'C' } elseif ($score -ge 40) { 'D' } else { 'F' }
$scoreColor = if ($score -ge 75) { '#1E8E52' } elseif ($score -ge 60) { '#A86A00' } else { '#C9343A' }

# ---------- HTML ----------
$stateStyle = @{ OK = 'ok'; Warning = 'warn'; Critical = 'crit'; Info = 'info'; Unknown = 'unk' }
$stateIcon = @{ OK = '&#10004;'; Warning = '&#9650;'; Critical = '&#10006;'; Info = '&#8505;'; Unknown = '?' }
$rows = ($checks | Sort-Object @{ e = { @{ Critical = 0; Warning = 1; Info = 2; Unknown = 3; OK = 4 }[$_.State] } }, Area | ForEach-Object {
        '<tr><td><span class="st {0}">{1} {2}</span></td><td>{3}</td><td><b>{4}</b><div class="d">{5}</div></td></tr>' -f $stateStyle[$_.State], $stateIcon[$_.State], $_.State, (Enc $_.Area), (Enc $_.Name), (Enc $_.Detail)
    }) -join "`n"

$facts = @(
    @('Computer', $env:COMPUTERNAME), @('Model', ('{0} {1}' -f $mfr, $model)), @('Serial', $serial),
    @('Operating system', ('{0} {1} (build {2}.{3})' -f $caption, $cv.DisplayVersion, $build, $cv.UBR)),
    @('CPU', $cpu.Name), @('Memory', (Fmt '{0} GB' @([math]::Round($cs.TotalPhysicalMemory / 1GB, 1)))), @('Scanned', (Get-Date -Format 'yyyy-MM-dd HH:mm'))
) | ForEach-Object { '<div>{0}</div><div>{1}</div>' -f (Enc $_[0]), (Enc $_[1]) }

$html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PC Health Report - $(Enc $env:COMPUTERNAME)</title>
<style>
body{margin:0;background:#F3F6FA;color:#0F1B2D;font:14px/1.5 "Segoe UI",Inter,Arial,sans-serif}
.w{max-width:960px;margin:0 auto;padding:32px 24px 48px}
.hd{display:flex;align-items:center;gap:12px}.hd b{font-size:18px}.hd b span{color:#E8960F}.hd small{color:#6B7C93;display:block}
.card{background:#fff;border:1px solid #E1E7EF;border-radius:12px;padding:22px;margin-top:18px;box-shadow:0 4px 16px rgba(15,27,45,.05)}
.top{display:flex;gap:28px;align-items:center;flex-wrap:wrap}
.score{width:132px;height:132px;border-radius:50%;display:grid;place-items:center;background:conic-gradient($scoreColor calc($score*1%),#E1E7EF 0)}
.score div{width:108px;height:108px;border-radius:50%;background:#fff;display:grid;place-items:center;text-align:center}
.score b{font-size:36px;line-height:1;color:$scoreColor}.score small{display:block;color:#6B7C93;font-size:11px;line-height:1.3;margin-top:4px}
.kv{display:grid;grid-template-columns:150px 1fr;gap:4px 14px;flex:1;min-width:300px}.kv div:nth-child(odd){color:#6B7C93}
table{width:100%;border-collapse:collapse}td{padding:10px 8px;border-top:1px solid #E1E7EF;vertical-align:top}
.d{color:#44566E;font-size:13px}
.st{display:inline-block;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:700;white-space:nowrap}
.ok{background:#E5F6EC;color:#1E8E52}.warn{background:#FFF3D9;color:#A86A00}.crit{background:#FDE7E8;color:#C9343A}.info{background:#E6EEF9;color:#2F67B1}.unk{background:#EEF1F5;color:#6B7C93}
.cta{background:#0F1B2D;color:#E8EEF6;border-radius:12px;padding:22px;margin-top:18px;display:flex;gap:18px;align-items:center;flex-wrap:wrap}
.cta b{color:#F5A524}.cta a{margin-left:auto;background:#F5A524;color:#1A1204;text-decoration:none;font-weight:700;padding:10px 16px;border-radius:8px}
.f{color:#6B7C93;font-size:12px;text-align:center;margin-top:22px}
@media print{.cta a{display:none}body{background:#fff}}
</style></head><body><div class="w">
<div class="hd"><svg width="40" height="40" viewBox="0 0 128 128"><rect x="4" y="4" width="120" height="120" rx="28" fill="#16243A"/><rect x="30" y="34" width="9" height="60" rx="4.5" fill="#8BA3BF"/><rect x="47" y="34" width="9" height="60" rx="4.5" fill="#8BA3BF"/><rect x="64" y="34" width="9" height="60" rx="4.5" fill="#8BA3BF"/><rect x="81" y="34" width="9" height="60" rx="4.5" fill="#8BA3BF"/><path d="M22 88 C 48 74, 74 56, 104 30 C 100 46, 90 58, 78 66 L 88 66 C 72 80, 50 90, 22 88 Z" fill="#F5A524"/></svg>
<div><b>Tally<span>Hawk</span> PC Health Report</b><small>Free edition v$ToolVersion$(if (-not $isAdmin) { ' &middot; limited scan (not run as administrator)' })</small></div></div>
<div class="card top"><div class="score"><div><div><b>$score</b><small>health<br>grade $grade</small></div></div></div><div class="kv">$($facts -join '')</div></div>
<div class="card"><table>$rows</table></div>
<div class="cta"><div><b>Managing more than one PC?</b><br>TallyHawk turns every PC into one fleet dashboard with software, warranty and license inventory, plus one-click fixes you can roll back.</div><a href="$ProUrl">See TallyHawk &rarr;</a></div>
<div class="f">Read-only report generated locally. No data was sent anywhere.</div>
</div></body></html>
"@

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $file = Join-Path $OutputPath ('PC-Health_{0}_{1}.html' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
    [IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding($false)))
    Write-Host ('  Health score: {0}/100 (grade {1})' -f $score, $grade) -ForegroundColor $(if ($score -ge 75) { 'Green' } elseif ($score -ge 60) { 'Yellow' } else { 'Red' })
    Write-Host ('  Report saved: {0}' -f $file) -ForegroundColor Green
    if (-not $NoOpen) { Start-Process $file }
}
catch {
    Write-Host ('  Could not write the report: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
