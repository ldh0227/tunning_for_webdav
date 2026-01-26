<#
.SYNOPSIS
    IIS & WebDAV Full Tuning Script (v3.0 - Refactored)
.DESCRIPTION
    Applies optimized settings for high-concurrency WebDAV environments.
    This script tunes OS-level TCP settings and IIS configurations based on user-selected sites.
.NOTES
    This script is based on the diagnostics from Check_IIS_Configs.ps1
#>

# =================================================================
# Part 0: Initial Setup
# =================================================================

# Check for Administrator privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "This script must be run as Administrator!"
    Start-Process powershell -Verb RunAs "-NoExit -File `"$PSCommandPath`""
    exit
}

Clear-Host
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   Trellix DLP IIS WebDAV Auto Tuning Script v3.0" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# =================================================================
# Part 1: OS-Level TCP/IP Tuning
# =================================================================

Write-Host ">>> Part 1: OS-Level TCP/IP Tuning" -ForegroundColor Cyan

# 1-1. Expand Ephemeral Port Range (MaxUserPort)
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
$maxPortValue = 65534
$currentMaxPort = (Get-ItemProperty -Path $regPath -Name "MaxUserPort" -ErrorAction SilentlyContinue).MaxUserPort

if ($currentMaxPort -eq $maxPortValue) {
    Write-Host " [OK] MaxUserPort is already set to $maxPortValue." -ForegroundColor Green
} else {
    Write-Host " [UPDATE] Setting MaxUserPort to $maxPortValue..." -ForegroundColor Yellow
    New-ItemProperty -Path $regPath -Name "MaxUserPort" -Value $maxPortValue -PropertyType DWORD -Force | Out-Null
    netsh int ipv4 set dynamicport tcp start=1025 num=64510
}

# 1-2. Shorten TIME_WAIT delay (TcpTimedWaitDelay)
$timeWaitValue = 30
$currentTimeWait = (Get-ItemProperty -Path $regPath -Name "TcpTimedWaitDelay" -ErrorAction SilentlyContinue).TcpTimedWaitDelay

if ($currentTimeWait -eq $timeWaitValue) {
    Write-Host " [OK] TcpTimedWaitDelay is already set to $timeWaitValue seconds." -ForegroundColor Green
} else {
    Write-Host " [UPDATE] Setting TcpTimedWaitDelay to $timeWaitValue seconds..." -ForegroundColor Yellow
    New-ItemProperty -Path $regPath -Name "TcpTimedWaitDelay" -Value $timeWaitValue -PropertyType DWORD -Force | Out-Null
}
Write-Host ""

# =================================================================
# Part 2: IIS Tuning (Site-Specific)
# =================================================================
Write-Host ">>> Part 2: IIS & WebDAV Performance Tuning" -ForegroundColor Cyan

Import-Module WebAdministration

Function Get-IISSiteSelection {
    try {
        $sites = @(Get-ChildItem -Path "IIS:\Sites")
        if ($sites.Count -eq 0) {
            Write-Error "No sites found in IIS."
            return $null
        }

        Write-Host "Select a site to tune:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $sites.Count; $i++) {
            $statusColor = if ($sites[$i].State -eq "Started") { "Green" } else { "Red" }
            Write-Host " [$($i+1)] $($sites[$i].Name)" -NoNewline
            Write-Host " (Status: $($sites[$i].State))" -ForegroundColor $statusColor
        }
        Write-Host ""

        $validSelection = $false
        while (-not $validSelection) {
            $selection = Read-Host "Enter number (1 ~ $($sites.Count)) or 'q' to quit"
            if ($selection -eq 'q') { return $null }
            if ($selection -match "^\d+$" -and [int]$selection -ge 1 -and [int]$selection -le $sites.Count) {
                return $sites[[int]$selection - 1].Name
            }
            else {
                Write-Host "Invalid number. Please try again." -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Error "Failed to retrieve site list: $_ "
        return $null
    }
}

Function Apply-WebConfigSettings {
    param(
        [string]$SiteName,
        [long]$MaxRequestLengthKB,
        [int]$ExecutionTimeoutSec
    )
    
    Write-Host " 4, 7. Applying web.config settings (maxRequestLength & executionTimeout)..."
    try {
        $sitePath = (Get-ItemProperty "IIS:\Sites\$SiteName").physicalPath
        $sitePath = [Environment]::ExpandEnvironmentVariables($sitePath)
        $webConfigPath = Join-Path -Path $sitePath -ChildPath "web.config"

        if (Test-Path $webConfigPath) {
            $xml = [xml](Get-Content $webConfigPath)
        } else {
            Write-Host "   [INFO] web.config not found. Creating a new one." -ForegroundColor Gray
            $xml = [xml]"<?xml version=`"1.0`" encoding=`"UTF-8`"?><configuration></configuration>"
        }

        # Ensure system.web section exists
        $systemWebServer = $xml.configuration.'system.web'
        if ($null -eq $systemWebServer) {
            $systemWebServer = $xml.CreateElement("system.web")
            $xml.configuration.AppendChild($systemWebServer) | Out-Null
        }

        # Ensure httpRuntime section exists
        $httpRuntime = $systemWebServer.httpRuntime
        if ($null -eq $httpRuntime) {
            $httpRuntime = $xml.CreateElement("httpRuntime")
            $systemWebServer.AppendChild($httpRuntime) | Out-Null
        }
        
        # Set Attributes
        $httpRuntime.SetAttribute("maxRequestLength", $MaxRequestLengthKB)
        $httpRuntime.SetAttribute("executionTimeout", $ExecutionTimeoutSec)
        
        $xml.Save($webConfigPath)
        Write-Host "   [OK] Set maxRequestLength='$MaxRequestLengthKB' KB, executionTimeout='$ExecutionTimeoutSec' sec." -ForegroundColor Green
    }
    catch { Write-Host "   [ERROR] Failed to update web.config: $_ " -ForegroundColor Red }
    Write-Host ""
}

# --- Main Execution ---

$TargetSite = Get-IISSiteSelection

if ($TargetSite) {
    Clear-Host
    Write-Host "========================================================" -ForegroundColor Yellow
    Write-Host "   Tuning Start for site: [$TargetSite]"
    Write-Host "========================================================" -ForegroundColor Yellow
    Write-Host ""
    
    $AppPoolName = (Get-ItemProperty "IIS:\Sites\$TargetSite").applicationPool
    $SitePathFilter = "system.webServer/security/requestFiltering"
    $LocationPath = $TargetSite
    
    # 1. UploadReadAheadSize
    Write-Host " 1. Setting UploadReadAheadSize to 52428800 bytes (50 MB)..."
    Set-WebConfigurationProperty -Filter "system.webServer/serverRuntime" -Name "uploadReadAheadSize" -Value 52428800 -PSPath "IIS:\" -Location $LocationPath -ErrorAction SilentlyContinue
    Write-Host "   [OK] Done." -ForegroundColor Green; Write-Host ""

    # 2. MinBytesPerSecond
    Write-Host " 2. Setting minBytesPerSecond to 0 (Disabled)..."
    Set-WebConfigurationProperty -Filter "system.applicationHost/webLimits" -Name "minBytesPerSecond" -Value 0
    Write-Host "   [OK] Done." -ForegroundColor Green; Write-Host ""

    # 3. MaxAllowedContentLength
    Write-Host " 3. Setting maxAllowedContentLength to 314572800 bytes (300 MB)..."
    Set-WebConfigurationProperty -Filter "$SitePathFilter/requestLimits" -Name "maxAllowedContentLength" -Value 314572800 -PSPath "IIS:\" -Location $LocationPath
    Write-Host "   [OK] Done." -ForegroundColor Green; Write-Host ""

    # 4 & 7. ASP.NET maxRequestLength & executionTimeout (web.config)
    Apply-WebConfigSettings -SiteName $TargetSite -MaxRequestLengthKB 307200 -ExecutionTimeoutSec 600

    # 5. AppPool Queue Length
    Write-Host " 5. Setting AppPool '$AppPoolName' queueLength to 65535..."
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "queueLength" -Value 65535
    Write-Host "   [OK] Done." -ForegroundColor Green; Write-Host ""

    # 6. Rapid Fail Protection
    Write-Host " 6. Disabling RapidFailProtection for '$AppPoolName'..."
    Set-WebConfigurationProperty -Filter "system.applicationHost/applicationPools/add[@name='$AppPoolName']/failure" -Name "rapidFailProtection" -Value "False" -PSPath "IIS:\"
    Write-Host "   [OK] Done." -ForegroundColor Green; Write-Host ""
    
    # 8. Connection Timeout
    Write-Host " 8. Setting Connection Timeout to 600 seconds (10 minutes)..."
    Set-WebConfigurationProperty -Filter "system.applicationHost/sites/site[@name='$TargetSite']/limits" -Name "connectionTimeout" -Value ([TimeSpan]::FromSeconds(600)) -PSPath "IIS:\"
    Write-Host "   [OK] Done." -ForegroundColor Green; Write-Host ""

    # 9. Request Filtering Verbs (Allow PUT)
    Write-Host " 9. Ensuring 'PUT' verb is allowed for WebDAV..."
    # Check if a rule for PUT already exists
    $putVerb = Get-WebConfigurationCollection -Filter "$SitePathFilter/verbs" -PSPath "IIS:\" -Location $LocationPath | Where-Object { $_.verb -eq 'PUT' }
    if ($putVerb) {
        if ($putVerb.allowed -ne "True") {
            $putVerb.allowed = "True"
        }
        Write-Host "   [INFO] PUT verb rule already exists, ensured it is set to 'Allowed'." -ForegroundColor Gray
    } else {
        Add-WebConfiguration -Filter "$SitePathFilter/verbs" -Value @{verb='PUT';allowed='True'} -PSPath "IIS:\" -Location $LocationPath
        Write-Host "   [OK] Added rule to allow 'PUT' verb." -ForegroundColor Green
    }
    Set-WebConfigurationProperty -Filter "$SitePathFilter/verbs" -Name "allowUnlisted" -Value "True" -PSPath "IIS:\" -Location $LocationPath
    Write-Host "   [OK] Set 'allowUnlisted' to True as a fallback." -ForegroundColor Green
    Write-Host ""
    
    # Extra: serverRuntime concurrent requests
    Write-Host " 10. Setting appConcurrentRequestLimit to 30000..."
    $appCmd = "$env:windir\system32\inetsrv\appcmd.exe"
    & $appCmd set config -section:serverRuntime /appConcurrentRequestLimit:30000
    Write-Host "   [OK] Done." -ForegroundColor Green; Write-Host ""

    # --- Completion Message ---
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "Tuning complete for [$TargetSite]." -ForegroundColor Yellow
    Write-Host "A server reboot is recommended to apply OS-level changes."
    Write-Host "========================================================" -ForegroundColor Cyan
    pause
} else {
    Write-Host "Tuning script aborted." -ForegroundColor Red
}
