<#
.SYNOPSIS
    IIS Default Web Site 기반 WebDAV Full Deployment & Tuning
.DESCRIPTION
    - 기본 사이트(Default Web Site)를 직접 튜닝하여 사용
    - .dlpenc MIME 타입 및 조각모음 비활성화 포함
    - epoadmin 계정 및 evidence 가상 디렉토리 구성
#>

# --- 사용자 입력 섹션 ---
$CertPath = Read-Host "인증서(.pfx) 파일의 전체 경로를 입력하세요"
$CertPassword = Read-Host "인증서 암호를 입력하세요" -AsSecureString
$EvidencePath = Read-Host "evidence 가상 디렉토리 경로를 입력하세요 (기본: D:\evidence)"
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = "D:\evidence" }

# --- 1. 관리자 권한 및 필수 기능 설치 ---
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "관리자 권한이 필요합니다."; exit
}

Write-Host ">>> IIS 및 WebDAV 설치 중..." -ForegroundColor Cyan
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console, Web-Dav-Publishing, Web-Filtering, Web-CertProvider -IncludeManagementTools

# --- 2. 리소스 최적화 (조각모음 및 불필요 서비스 비활성화) ---
Write-Host ">>> 리소스 최적화 진행 중..." -ForegroundColor Cyan
Get-ScheduledTask -TaskName "ScheduledDefrag" -ErrorAction SilentlyContinue | Disable-ScheduledTask
Stop-Service -Name "defragsvc" -ErrorAction SilentlyContinue
Set-Service -Name "defragsvc" -StartupType Disabled

# 기존 튜닝 가이드 기반 서비스 중단 (WSearch, BITS)[cite: 1]
$DisableServices = @("WSearch", "Bits")
foreach ($svc in $DisableServices) {
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    Set-Service $svc -StartupType Disabled
}

# --- 3. 로컬 계정(epoadmin) 생성 및 권한 부여 ---
Write-Host ">>> epoadmin 계정 및 권한 설정..." -ForegroundColor Cyan
if (!(Get-LocalUser -Name "epoadmin" -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name "epoadmin" -Password (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force) -Description "WebDAV Admin Account"
}

if (!(Test-Path $EvidencePath)) { New-Item -Path $EvidencePath -ItemType Directory -Force }
$Acl = Get-Acl $EvidencePath
$Ar = New-Object System.Security.AccessControl.FileSystemAccessRule("epoadmin", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.SetAccessRule($Ar)
Set-Acl $EvidencePath $Acl

# --- 4. 기본 사이트(Default Web Site) 구성 및 MIME 타입 ---
Import-Module WebAdministration
$SiteName = "Default Web Site"

# 기본 사이트가 중지되어 있다면 시작
Start-Website -Name $SiteName -ErrorAction SilentlyContinue

# dlpenc MIME 타입 추가
Write-Host ">>> MIME 타입 추가 (.dlpenc)..." -ForegroundColor Cyan
if (!(Get-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." | Where-Object { $_.fileExtension -eq ".dlpenc" })) {
    Add-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -Value @{fileExtension='.dlpenc'; mimeType='application/octet-stream'}
}

# evidence 가상 디렉토리 생성 (기본 사이트 하위)
if (!(Get-WebVirtualDirectory -Site $SiteName -Name "evidence" -ErrorAction SilentlyContinue)) {
    New-WebVirtualDirectory -Site $SiteName -Name "evidence" -PhysicalPath $EvidencePath
}

# --- 5. 인증서 등록 및 HTTPS 바인딩 (기본 사이트에 적용) ---
Write-Host ">>> SSL 인증서 등록 및 기본 사이트 바인딩..." -ForegroundColor Cyan
try {
    $pfx = Import-PfxCertificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\My -Password $CertPassword -Exportable
    $Thumbprint = $pfx.Thumbprint
    
    # 기본 사이트에 443 포트 바인딩 추가
    if (!(Get-WebBinding -Name $SiteName -Protocol "https")) {
        New-WebBinding -Name $SiteName -Protocol "https" -Port 443 -SslFlags 0
    }
    
    $CertHash = (Get-ChildItem Cert:\LocalMachine\My\$Thumbprint)
    $CertHash | New-Item -Path "IIS:\SslBindings\0.0.0.0!443" -Force
} catch {
    Write-Warning "인증서 설정 중 오류가 발생했으나 나머지 튜닝은 계속됩니다."
}

# --- 6. WebDAV 및 고성능 튜닝 (tunning_for_webdav.ps1 로직) ---[cite: 1]
Write-Host ">>> WebDAV 활성화 및 커널 튜닝 적용..." -ForegroundColor Cyan
Set-WebConfigurationProperty -Filter "system.webServer/webdav/authoring" -Name "enabled" -Value "True" -PSPath "IIS:\"

# IIS 커널/앱풀 튜닝
$appCmd = "$env:windir\system32\inetsrv\appcmd.exe"
& $appCmd set config -section:serverRuntime /appConcurrentRequestLimit:30000 /uploadReadAheadSize:52428800
& $appCmd set config /section:webLimits /minBytesPerSecond:0
Set-ItemProperty "IIS:\AppPools\DefaultAppPool" -Name "queueLength" -Value 65535

# 추가된 고성능/안정성 튜닝 (tunning_for_webdav.ps1 일관성 확보)
$SitePathFilter = "system.webServer/security/requestFiltering"
Set-WebConfigurationProperty -Filter "$SitePathFilter/requestLimits" -Name "maxAllowedContentLength" -Value 314572800 -PSPath "IIS:\" -Location $SiteName

# ASP.NET maxRequestLength & executionTimeout (web.config 설정)
try {
    $sitePathInfo = (Get-ItemProperty "IIS:\Sites\$SiteName").physicalPath
    $sitePathInfo = [Environment]::ExpandEnvironmentVariables($sitePathInfo)
    $webConfigPath = Join-Path -Path $sitePathInfo -ChildPath "web.config"

    if (Test-Path $webConfigPath) {
        $xml = [xml](Get-Content $webConfigPath)
    } else {
        $xml = [xml]"<?xml version=`"1.0`" encoding=`"UTF-8`"?><configuration></configuration>"
    }

    $systemWeb = $xml.configuration.'system.web'
    if ($null -eq $systemWeb) {
        $systemWeb = $xml.CreateElement("system.web")
        $xml.configuration.AppendChild($systemWeb) | Out-Null
    }

    $httpRuntime = $systemWeb.httpRuntime
    if ($null -eq $httpRuntime) {
        $httpRuntime = $xml.CreateElement("httpRuntime")
        $systemWeb.AppendChild($httpRuntime) | Out-Null
    }
    
    $httpRuntime.SetAttribute("maxRequestLength", "307200")
    $httpRuntime.SetAttribute("executionTimeout", "600")
    
    $xml.Save($webConfigPath)
} catch { Write-Warning "web.config 업데이트 실패: $_" }

# Rapid Fail Protection 비활성화
Set-WebConfigurationProperty -Filter "system.applicationHost/applicationPools/add[@name='DefaultAppPool']/failure" -Name "rapidFailProtection" -Value "False" -PSPath "IIS:\"

# Connection Timeout 설정
Set-WebConfigurationProperty -Filter "system.applicationHost/sites/site[@name='$SiteName']/limits" -Name "connectionTimeout" -Value ([TimeSpan]::FromSeconds(600)) -PSPath "IIS:\"

# Request Filtering Verbs (PUT 허용)
$putVerb = Get-WebConfigurationCollection -Filter "$SitePathFilter/verbs" -PSPath "IIS:\" -Location $SiteName | Where-Object { $_.verb -eq 'PUT' }
if ($putVerb) {
    if ($putVerb.allowed -ne "True") { $putVerb.allowed = "True" }
} else {
    Add-WebConfiguration -Filter "$SitePathFilter/verbs" -Value @{verb='PUT';allowed='True'} -PSPath "IIS:\" -Location $SiteName
}
Set-WebConfigurationProperty -Filter "$SitePathFilter/verbs" -Name "allowUnlisted" -Value "True" -PSPath "IIS:\" -Location $SiteName

# OS TCP 파라미터 최적화
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
New-ItemProperty -Path $regPath -Name "MaxUserPort" -Value 65534 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $regPath -Name "TcpTimedWaitDelay" -Value 30 -PropertyType DWORD -Force | Out-Null
netsh int ipv4 set dynamicport tcp start=1025 num=64510

Write-Host "======================================================" -ForegroundColor Green
Write-Host "  기본 사이트(Default Web Site) 기반 구성 완료"
Write-Host "  - 가상 디렉토리: https://(서버IP)/evidence"
Write-Host "  - 모든 튜닝 및 .dlpenc MIME 설정 포함"
Write-Host "======================================================" -ForegroundColor Green