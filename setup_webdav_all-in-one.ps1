<#
.SYNOPSIS
    IIS Default Web Site based WebDAV Full Deployment & Tuning
.DESCRIPTION
    - Direct tuning of the Default Web Site
    - Includes .dlpenc MIME type and defrag disablement
    - Configures epoadmin account and evidence virtual directory
#>

# --- User Input Section ---
$CertPath = Read-Host "Enter the full path to the certificate (.pfx) file"
$CertPassword = Read-Host "Enter the certificate password" -AsSecureString
$EvidencePath = Read-Host "Enter the evidence virtual directory path (Default: D:\evidence)"
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = "D:\evidence" }

# --- 1. Administrator Privileges and Prerequisites Installation ---
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Administrator privileges are required."; exit
}

Write-Host ">>> Installing IIS and WebDAV..." -ForegroundColor Cyan
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console, Web-Dav-Publishing, Web-Filtering, Web-CertProvider, Web-Windows-Auth -IncludeManagementTools

# --- 2. Resource Optimization (Disable Defrag and Unnecessary Services) ---
Write-Host ">>> Optimizing resources..." -ForegroundColor Cyan
Get-ScheduledTask -TaskName "ScheduledDefrag" -ErrorAction SilentlyContinue | Disable-ScheduledTask
Stop-Service -Name "defragsvc" -ErrorAction SilentlyContinue
Set-Service -Name "defragsvc" -StartupType Disabled

# Stop services based on tuning guide (WSearch, BITS)
$DisableServices = @("WSearch", "Bits")
foreach ($svc in $DisableServices) {
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    Set-Service $svc -StartupType Disabled
}

# --- 3. Local Account (epoadmin) Creation and Permissions ---
Write-Host ">>> Configuring epoadmin account and permissions..." -ForegroundColor Cyan
if (!(Get-LocalUser -Name "epoadmin" -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name "epoadmin" -Password (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force) -Description "WebDAV Admin Account"
}

if (!(Test-Path $EvidencePath)) { New-Item -Path $EvidencePath -ItemType Directory -Force }
$Acl = Get-Acl $EvidencePath
$Ar = New-Object System.Security.AccessControl.FileSystemAccessRule("epoadmin", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.SetAccessRule($Ar)
Set-Acl $EvidencePath $Acl

# --- 4. Default Web Site Configuration and MIME Types ---
Import-Module WebAdministration
$SiteName = "Default Web Site"

# Start default site if stopped
Start-Website -Name $SiteName -ErrorAction SilentlyContinue

# Add dlpenc MIME type
Write-Host ">>> Adding MIME type (.dlpenc)..." -ForegroundColor Cyan
$mimeExists = Get-WebConfiguration -Filter "system.webServer/staticContent/mimeMap[@fileExtension='.dlpenc']" -ErrorAction SilentlyContinue
if (-not $mimeExists) {
    Add-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -Value @{fileExtension='.dlpenc'; mimeType='application/octet-stream'}
}

# Add extensionless (.) MIME type
Write-Host ">>> Adding MIME type (.)..." -ForegroundColor Cyan
$mimeExistsDot = Get-WebConfiguration -Filter "system.webServer/staticContent/mimeMap[@fileExtension='.']" -ErrorAction SilentlyContinue
if (-not $mimeExistsDot) {
    Add-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -Value @{fileExtension='.'; mimeType='application/octet-stream'}
}

# Create evidence virtual directory (under default site)
if (!(Get-WebVirtualDirectory -Site $SiteName -Name "evidence" -ErrorAction SilentlyContinue)) {
    New-WebVirtualDirectory -Site $SiteName -Name "evidence" -PhysicalPath $EvidencePath
}

# --- 5. Certificate Registration and HTTPS Binding (Default Site) ---
Write-Host ">>> Registering SSL certificate and binding to Default Web Site..." -ForegroundColor Cyan
try {
    $pfx = Import-PfxCertificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\My -Password $CertPassword -Exportable
    $Thumbprint = $pfx.Thumbprint
    
    # Add 443 port binding to default site
    if (!(Get-WebBinding -Name $SiteName -Protocol "https")) {
        New-WebBinding -Name $SiteName -Protocol "https" -Port 443 -SslFlags 0
    }
    
    $CertHash = (Get-ChildItem Cert:\LocalMachine\My\$Thumbprint)
    $CertHash | New-Item -Path "IIS:\SslBindings\0.0.0.0!443" -Force
} catch {
    Write-Warning "Error during certificate setup, but remaining tuning will continue."
}

# --- 6. WebDAV and Performance Tuning (tunning_for_webdav.ps1 logic) ---
Write-Host ">>> Enabling WebDAV and applying kernel tuning..." -ForegroundColor Cyan
Set-WebConfigurationProperty -Filter "system.webServer/webdav/authoring" -Name "enabled" -Value "True" -PSPath "IIS:\"

# Windows Authentication and Anonymous disable for evidence dir
Write-Host ">>> Configuring Windows Authentication..." -ForegroundColor Cyan
Set-WebConfigurationProperty -Filter "system.webServer/security/authentication/anonymousAuthentication" -Name "enabled" -Value "False" -PSPath "IIS:\" -Location "$SiteName/evidence"
Set-WebConfigurationProperty -Filter "system.webServer/security/authentication/windowsAuthentication" -Name "enabled" -Value "True" -PSPath "IIS:\" -Location "$SiteName/evidence"

# WebDAV Authoring Rule for evidence dir
Write-Host ">>> Adding WebDAV Authoring Rule..." -ForegroundColor Cyan
$ruleExists = Get-WebConfiguration -Filter "system.webServer/webdav/authoring/rules/add[@users='*']" -PSPath "IIS:\" -Location "$SiteName/evidence" -ErrorAction SilentlyContinue
if (-not $ruleExists) {
    Add-WebConfiguration -Filter "system.webServer/webdav/authoring/rules" -Value @{users='*';roles='';permissions='Read, Source, Write'} -PSPath "IIS:\" -Location "$SiteName/evidence"
}

# Enable Directory Browsing for evidence dir
Write-Host ">>> Enabling Directory Browsing..." -ForegroundColor Cyan
Set-WebConfigurationProperty -Filter "system.webServer/directoryBrowse" -Name "enabled" -Value "True" -PSPath "IIS:\" -Location "$SiteName/evidence"

# IIS Kernel/AppPool Tuning
$appCmd = "$env:windir\system32\inetsrv\appcmd.exe"
& $appCmd set config -section:serverRuntime /appConcurrentRequestLimit:30000 /uploadReadAheadSize:52428800
& $appCmd set config /section:webLimits /minBytesPerSecond:0
Set-ItemProperty "IIS:\AppPools\DefaultAppPool" -Name "queueLength" -Value 65535

# Added Performance/Stability Tuning (consistency with tunning_for_webdav.ps1)
$SitePathFilter = "system.webServer/security/requestFiltering"
Set-WebConfigurationProperty -Filter "$SitePathFilter/requestLimits" -Name "maxAllowedContentLength" -Value 314572800 -PSPath "IIS:\" -Location $SiteName

# ASP.NET maxRequestLength & executionTimeout (web.config setting)
try {
    $sitePathInfo = (Get-ItemProperty "IIS:\Sites\$SiteName").physicalPath
    $sitePathInfo = [Environment]::ExpandEnvironmentVariables($sitePathInfo)
    $webConfigPath = Join-Path -Path $sitePathInfo -ChildPath "web.config"

    if (Test-Path $webConfigPath) {
        $xml = [xml](Get-Content $webConfigPath)
    } else {
        $xml = [xml]"<?xml version=`"1.0`" encoding=`"UTF-8`"?><configuration></configuration>"
    }

    $systemWeb = $xml.SelectSingleNode("/configuration/system.web")
    if ($null -eq $systemWeb) {
        $systemWeb = $xml.CreateElement("system.web")
        $xml.SelectSingleNode("/configuration").AppendChild($systemWeb) | Out-Null
    }

    $httpRuntime = $systemWeb.SelectSingleNode("httpRuntime")
    if ($null -eq $httpRuntime) {
        $httpRuntime = $xml.CreateElement("httpRuntime")
        $systemWeb.AppendChild($httpRuntime) | Out-Null
    }
    
    $httpRuntime.SetAttribute("maxRequestLength", "307200")
    $httpRuntime.SetAttribute("executionTimeout", "600")
    
    $xml.Save($webConfigPath)
} catch { Write-Warning "web.config update failed: $_" }

# Disable Rapid Fail Protection
Set-WebConfigurationProperty -Filter "system.applicationHost/applicationPools/add[@name='DefaultAppPool']/failure" -Name "rapidFailProtection" -Value "False" -PSPath "IIS:\"

# Connection Timeout Setting
Set-WebConfigurationProperty -Filter "system.applicationHost/sites/site[@name='$SiteName']/limits" -Name "connectionTimeout" -Value ([TimeSpan]::FromSeconds(600)) -PSPath "IIS:\"

# Request Filtering Verbs (Allow PUT)
$putVerb = Get-WebConfiguration -Filter "$SitePathFilter/verbs/add[@verb='PUT']" -PSPath "IIS:\" -Location $SiteName -ErrorAction SilentlyContinue
if ($putVerb) {
    if ($putVerb.allowed -ne "True") {
        Set-WebConfigurationProperty -Filter "$SitePathFilter/verbs/add[@verb='PUT']" -Name "allowed" -Value "True" -PSPath "IIS:\" -Location $SiteName
    }
} else {
    Add-WebConfiguration -Filter "$SitePathFilter/verbs" -Value @{verb='PUT';allowed='True'} -PSPath "IIS:\" -Location $SiteName
}
Set-WebConfigurationProperty -Filter "$SitePathFilter/verbs" -Name "allowUnlisted" -Value "True" -PSPath "IIS:\" -Location $SiteName

# OS TCP Parameter Optimization
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
New-ItemProperty -Path $regPath -Name "MaxUserPort" -Value 65534 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $regPath -Name "TcpTimedWaitDelay" -Value 30 -PropertyType DWORD -Force | Out-Null
netsh int ipv4 set dynamicport tcp start=1025 num=64510

Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Default Web Site based configuration completed"
Write-Host "  - Virtual Directory: https://(ServerIP)/evidence"
Write-Host "  - All tuning and .dlpenc MIME settings included"
Write-Host "======================================================" -ForegroundColor Green