# ==========================================
# Windows Server 2022 IIS WebDAV Tuning Script
# Target: 16,000+ Agents High Concurrency
# ==========================================

Write-Host ">>> 1. TCP/IP 포트 튜닝 시작 (OS 레벨)" -ForegroundColor Cyan

# 1-1. Ephemeral Port 범위 확장 (MaxUserPort)
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
$maxPort = Get-ItemProperty -Path $regPath -Name "MaxUserPort" -ErrorAction SilentlyContinue

if ($maxPort.MaxUserPort -eq 65534) {
    Write-Host "[OK] MaxUserPort가 이미 65534로 설정되어 있습니다."
} else {
    Write-Host "[UPDATE] MaxUserPort를 65534로 변경합니다." -ForegroundColor Yellow
    New-ItemProperty -Path $regPath -Name "MaxUserPort" -Value 65534 -PropertyType DWORD -Force | Out-Null
    # 동적 포트 범위 커맨드 병행 실행
    netsh int ipv4 set dynamicport tcp start=1025 num=64510
}

# 1-2. TIME_WAIT 대기 시간 단축 (TcpTimedWaitDelay)
$timeWait = Get-ItemProperty -Path $regPath -Name "TcpTimedWaitDelay" -ErrorAction SilentlyContinue

if ($timeWait.TcpTimedWaitDelay -eq 30) {
    Write-Host "[OK] TcpTimedWaitDelay가 이미 30초로 설정되어 있습니다."
} else {
    Write-Host "[UPDATE] TcpTimedWaitDelay를 30초로 변경합니다." -ForegroundColor Yellow
    New-ItemProperty -Path $regPath -Name "TcpTimedWaitDelay" -Value 30 -PropertyType DWORD -Force | Out-Null
}

Write-Host "`n>>> 2. IIS 성능 튜닝 시작" -ForegroundColor Cyan
Import-Module WebAdministration

# 2-1. 애플리케이션 풀 큐 길이 (Queue Length)
$appPoolName = "DefaultAppPool" # 실제 사용하는 AppPool 이름으로 변경 필요하면 수정하세요
try {
    $currentQueue = Get-ItemProperty "IIS:\AppPools\$appPoolName" -Name "queueLength"
    if ($currentQueue.queueLength -eq 20000) {
        Write-Host "[OK] $appPoolName 큐 길이가 이미 20000입니다."
    } else {
        Write-Host "[UPDATE] $appPoolName 큐 길이를 20000으로 변경합니다." -ForegroundColor Yellow
        Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name "queueLength" -Value 20000
    }
} catch {
    Write-Host "[ERROR] AppPool($appPoolName)을 찾을 수 없습니다. 이름을 확인해주세요." -ForegroundColor Red
}

# 2-2. serverRuntime 동시 요청 제한 (appConcurrentRequestLimit)
# 이 설정은 applicationHost.config를 직접 건드리므로 appcmd를 사용합니다.
$appCmd = "$env:windir\system32\inetsrv\appcmd.exe"
Write-Host "[UPDATE] serverRuntime/appConcurrentRequestLimit를 30000으로 설정합니다 (강제 적용)." -ForegroundColor Yellow
& $appCmd set config /section:serverRuntime /appConcurrentRequestLimit:30000

Write-Host "`n=========================================="
Write-Host " 모든 설정 완료. 서버를 재부팅해야 OS 레벨 설정이 완벽히 적용됩니다." -ForegroundColor Green
Write-Host "=========================================="