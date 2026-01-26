<#
.SYNOPSIS
    IIS & WebDAV Configuration Health Check Tool (v3.0 - Refactored)
.DESCRIPTION
    Automatically lists IIS sites for selection and performs detailed diagnostics
    on 6+ key causes of WebDAV 500 errors (Buffer, Timeout, Limits, Queue, etc.).
#>

# Check for Administrator privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "This script must be run as Administrator!"
    break
}

Import-Module WebAdministration

Function Get-IISSiteSelection {
    try {
        $sites = @(Get-ChildItem -Path "IIS:\Sites")
        if ($sites.Count -eq 0) {
            Write-Error "No sites found in IIS."
            return $null
        }

        Write-Host "Select a site to inspect:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $sites.Count; $i++) {
            $statusColor = if ($sites[$i].State -eq "Started") { "Green" } else { "Red" }
            Write-Host " [$($i+1)] $($sites[$i].Name)" -NoNewline
            Write-Host " (Status: $($sites[$i].State))" -ForegroundColor $statusColor
        }
        Write-Host ""

        $validSelection = $false
        while (-not $validSelection) {
            $selection = Read-Host "Enter number (1 ~ $($sites.Count))"
            if ($selection -match "^\d+$" -and [int]$selection -ge 1 -and [int]$selection -le $sites.Count) {
                return $sites[[int]$selection - 1].Name
            }
            else {
                Write-Host "Invalid number. Please try again." -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Error "Failed to retrieve site list: $_"
        return $null
    }
}

Function Check-UploadReadAheadSize ($SiteName) {
    Write-Host "1. UploadReadAheadSize (Buffer Size)" -ForegroundColor Green
    try {
        $val = Get-WebConfigurationProperty -Filter "system.webServer/serverRuntime" -Name "uploadReadAheadSize" -PSPath "IIS:\" -Location $SiteName
        if ($null -eq $val.Value) {
            Write-Host "   [INFO] Value not set, using default (48KB)." -ForegroundColor Red
            Write-Host "   -> Recommend: Set to 50MB (52,428,800 Bytes) or more." -ForegroundColor Gray
        }
        else {
            $sizeMB = [math]::Round($val.Value / 1MB, 2)
            Write-Host "   - Current: $($val.Value) Bytes ($sizeMB MB)"
            if ($val.Value -lt 50MB) {
                Write-Host "   [WARNING] Value is too small. (Recommend: > 50MB)" -ForegroundColor Red
            }
            else {
                Write-Host "   [OK] Sufficient." -ForegroundColor Cyan
            }
        }
    }
    catch { Write-Host "   [ERROR] Failed to check: $_" -ForegroundColor Red }
    Write-Host ""
}

Function Check-MinBytesPerSecond {
    Write-Host "2. minBytesPerSecond (Low Speed Connection Throttle)" -ForegroundColor Green
    try {
        $val = Get-WebConfigurationProperty -Filter "system.applicationHost/webLimits" -Name "minBytesPerSecond"
        Write-Host "   - Current: $($val.Value) Bytes/sec"
        if ($val.Value -eq 0) {
            Write-Host "   [OK] Set to 0 (Disabled). Prevents 12030 errors." -ForegroundColor Cyan
        }
        else {
            Write-Host "   [FAIL] Not 0. Slow clients may be disconnected forcibly." -ForegroundColor Red
        }
    }
    catch { Write-Host "   [ERROR] Failed to check: $_" -ForegroundColor Red }
    Write-Host ""
}

Function Check-MaxAllowedContentLength ($SiteName) {
    Write-Host "3. maxAllowedContentLength (IIS Request Limit)" -ForegroundColor Green
    try {
        $val = Get-WebConfigurationProperty -Filter "system.webServer/security/requestFiltering/requestLimits" -Name "maxAllowedContentLength" -PSPath "IIS:\" -Location $SiteName
        $sizeMB = [math]::Round($val.Value / 1MB, 2)
        Write-Host "   - Current: $($val.Value) Bytes ($sizeMB MB)"
        # 300MB = 314,572,800 bytes
        if ($val.Value -lt 300MB) { 
            Write-Host "   [WARNING] Less than 300MB." -ForegroundColor Yellow
        }
        else {
            Write-Host "   [OK] 300MB or more." -ForegroundColor Cyan
        }
    }
    catch { Write-Host "   [INFO] Default value (30MB) might be in use." -ForegroundColor Gray }
    Write-Host ""
}

Function Check-AspMaxRequestLength ($SiteName) {
    Write-Host "4. ASP.NET maxRequestLength (Runtime Limit)" -ForegroundColor Green
    try {
        $sitePath = Get-ItemProperty "IIS:\Sites\$SiteName" | Select-Object -ExpandProperty physicalPath
        $sitePath = [Environment]::ExpandEnvironmentVariables($sitePath)
        $webConfigPath = Join-Path -Path $sitePath -ChildPath "web.config"
        
        if (Test-Path $webConfigPath) {
            [xml]$config = Get-Content $webConfigPath
            $httpRuntime = $config.configuration.'system.web'.httpRuntime
            
            if ($httpRuntime) {
                $maxReqLenKB = $httpRuntime.maxRequestLength
                if ($maxReqLenKB) {
                    $maxReqMB = [math]::Round($maxReqLenKB / 1KB, 2) # maxRequestLength is in KB
                    Write-Host "   - Current: $maxReqLenKB KB ($maxReqMB MB)"
                    # 300MB in KB = 307200 KB
                    if ($maxReqLenKB -lt 307200) {
                        Write-Host "   [FAIL] Less than 300MB. Major cause of 'Immediate 500 Error'." -ForegroundColor Red
                    }
                    else {
                        Write-Host "   [OK] 300MB or more." -ForegroundColor Cyan
                    }
                }
                else {
                    Write-Host "   [FAIL] maxRequestLength attribute missing. (Default 4MB is applied -> Immediate Failure)" -ForegroundColor Red
                }
            }
            else {
                Write-Host "   [FAIL] <httpRuntime> tag missing. (Default 4MB is applied -> Immediate Failure)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "   [WARNING] web.config file not found: $webConfigPath" -ForegroundColor Yellow
        }
    }
    catch { Write-Host "   [ERROR] web.config parse error: $_" -ForegroundColor Red }
    Write-Host ""
}

Function Check-AppPoolQueueLength ($SiteName) {
    Write-Host "5. AppPool Queue Length" -ForegroundColor Green
    try {
        $appPoolName = (Get-ItemProperty "IIS:\Sites\$SiteName").applicationPool
        $queueLength = (Get-ItemProperty "IIS:\AppPools\$appPoolName" -Name "queueLength").Value
        
        Write-Host "   - AppPool Name: $appPoolName"
        Write-Host "   - Queue Length: $queueLength"
        
        if ($queueLength -lt 4000) {
            Write-Host "   [WARNING] Queue length ($queueLength) is small for high traffic." -ForegroundColor Yellow
            Write-Host "   -> Recommend: Increase to 5000+ (Prevents 503 errors during spikes)" -ForegroundColor Gray
        }
        else {
            Write-Host "   [OK] Queue length is sufficient." -ForegroundColor Cyan
        }
    }
    catch { Write-Host "   [ERROR] Failed to get AppPool info: $_" -ForegroundColor Red }
    Write-Host ""
}

Function Check-RapidFailProtection ($SiteName) {
    Write-Host "6. Rapid Fail Protection" -ForegroundColor Green
    try {
        $appPoolName = (Get-ItemProperty "IIS:\Sites\$SiteName").applicationPool
        $failure = Get-WebConfigurationProperty -Filter "system.applicationHost/applicationPools/add[@name='$appPoolName']/failure" -Name "rapidFailProtection" -PSPath "IIS:\"
        
        Write-Host "   - RapidFailProtection: $($failure.Value)"
        
        if ($failure.Value -eq "True") {
            Write-Host "   [INFO] Enabled. AppPool may stop if errors spike." -ForegroundColor Gray
        }
        else {
            Write-Host "   [OK] Disabled (Service won't be forcibly stopped)." -ForegroundColor Cyan
        }
    }
    catch { Write-Host "   [ERROR] Failed to check: $_" -ForegroundColor Red }
    Write-Host ""
}

Function Check-ExecutionTimeout ($SiteName) {
    Write-Host "7. executionTimeout (Script Execution Limit)" -ForegroundColor Green
    try {
        $sitePath = Get-ItemProperty "IIS:\Sites\$SiteName" | Select-Object -ExpandProperty physicalPath
        $sitePath = [Environment]::ExpandEnvironmentVariables($sitePath)
        $webConfigPath = Join-Path -Path $sitePath -ChildPath "web.config"
        
        if (Test-Path $webConfigPath) {
            [xml]$config = Get-Content $webConfigPath
            $httpRuntime = $config.configuration.'system.web'.httpRuntime
            
            if ($httpRuntime) {
                $execTimeout = $httpRuntime.executionTimeout
                if ($execTimeout) {
                    Write-Host "   - Current: $execTimeout seconds"
                    
                    if ([int]$execTimeout -lt 600) {
                        Write-Host "   [WARNING] Less than 600s (10m). Large uploads might timeout." -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "   [OK] Sufficient." -ForegroundColor Cyan
                    }
                }
                else {
                    Write-Host "   [INFO] executionTimeout attribute missing. (Default 110s applied)" -ForegroundColor Gray
                }
            }
            else {
                Write-Host "   [INFO] <httpRuntime> tag missing. (Default 110s applied)" -ForegroundColor Gray
            }
        }
        else {
            Write-Host "   [WARNING] web.config file not found: $webConfigPath" -ForegroundColor Yellow
        }
    }
    catch { Write-Host "   [ERROR] web.config parse error: $_" -ForegroundColor Red }
    Write-Host ""
}

Function Check-ConnectionTimeout ($SiteName) {
    Write-Host "8. Connection Timeout" -ForegroundColor Green
    try {
        $val = Get-WebConfigurationProperty -Filter "system.applicationHost/sites/site[@name='$SiteName']/limits" -Name "connectionTimeout" -PSPath "IIS:\"
       
        if ($val.Value) {
            Write-Host "   - Current: $($val.Value)"
            if ($val.Value.TotalSeconds -lt 120) {
                Write-Host "   [WARNING] Connection timeout might be too short." -ForegroundColor Yellow
            }
            else {
                Write-Host "   [OK] Appropriate." -ForegroundColor Cyan
            }
        }
        else {
            Write-Host "   [INFO] Default (120s) in use." -ForegroundColor Gray
        }
    }
    catch { Write-Host "   [ERROR] Failed to check: $_" -ForegroundColor Red }
    Write-Host ""
}

Function Check-RequestFilteringVerbs ($SiteName) {
    Write-Host "9. Request Filtering Verbs (PUT Method)" -ForegroundColor Green
    try {
        $filterSection = Get-WebConfigurationProperty -Filter "system.webServer/security/requestFiltering/verbs" -Name "." -PSPath "IIS:\" -Location $SiteName
        
        $allowUnlisted = $filterSection.allowUnlisted
        $verbs = Get-WebConfigurationProperty -Filter "system.webServer/security/requestFiltering/verbs" -Name "add" -PSPath "IIS:\" -Location $SiteName
        
        Write-Host "   - allowUnlisted: $allowUnlisted"
        
        $putRule = $verbs | Where-Object { $_.verb -eq "PUT" }

        if ($allowUnlisted -eq $false) {
            if ($putRule.allowed -eq $true) {
                Write-Host "   [OK] PUT method explicitly allowed." -ForegroundColor Cyan
            }
            else {
                Write-Host "   [FAIL] allowUnlisted is false and PUT is NOT explicitly allowed." -ForegroundColor Red
            }
        }
        else {
            if ($putRule.allowed -eq $false) {
                Write-Host "   [FAIL] PUT method explicitly denied (allowed=false)." -ForegroundColor Red
            }
            else {
                Write-Host "   [OK] PUT method allowed (Implicitly or explicitly)." -ForegroundColor Cyan
            }
        }

    }
    catch { Write-Host "   [ERROR] Failed to check: $_" -ForegroundColor Red }
    Write-Host ""
}

# --- Main Execution ---

Clear-Host
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   Trellix DLP IIS WebDAV Health Check Tool v3.0" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

$TargetSite = Get-IISSiteSelection

if ($TargetSite) {
    Clear-Host
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "   Diagnosis Start: [$TargetSite]" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""

    Check-UploadReadAheadSize -SiteName $TargetSite
    Check-MinBytesPerSecond
    Check-MaxAllowedContentLength -SiteName $TargetSite
    Check-AspMaxRequestLength -SiteName $TargetSite
    Check-AppPoolQueueLength -SiteName $TargetSite
    Check-RapidFailProtection -SiteName $TargetSite
    Check-ExecutionTimeout -SiteName $TargetSite
    Check-ConnectionTimeout -SiteName $TargetSite
    Check-RequestFilteringVerbs -SiteName $TargetSite

    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "Diagnosis Complete. Prioritize fixing [FAIL] items." -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Cyan
    pause
}