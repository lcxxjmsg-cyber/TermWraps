# Core.Health.ps1 - TermWrap 健康分级 + termsrv 变化检测 + 看门狗
# 语义重写：无 INI → 三元健康分级（Healthy / Degraded / Failed）
# 复用 rdpwarps.ps1 的：Test-RdpProtocolHandshake（握手）、会话枚举、计划任务注册模式

$script:WATCHDOG_TASK = 'termwrap-Watchdog'
$script:WATCHDOG_SCRIPT = "$env:ProgramData\rdpwarp\watchdog.ps1"
$script:STATE_DIR = "$env:ProgramData\rdpwarp"
$script:STATE_TERMSRV = Join-Path $script:STATE_DIR 'termsrv-last.txt'

function Test-RdpProtocolHandshake {
    param([int]$Port,[int]$TimeoutMs=2500)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connect = $client.BeginConnect('127.0.0.1',$Port,$null,$null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($connect)
        $stream = $client.GetStream(); $stream.ReadTimeout = $TimeoutMs; $stream.WriteTimeout = $TimeoutMs
        [byte[]]$request = 0x03,0x00,0x00,0x13,0x0e,0xe0,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x08,0x00,0x03,0x00,0x00,0x00
        $stream.Write($request,0,$request.Length)
        $buffer = New-Object byte[] 64
        $count = $stream.Read($buffer,0,$buffer.Length)
        return ($count -ge 11 -and $buffer[0] -eq 3)
    } catch { return $false } finally { if ($client) { $client.Close() } }
}

function Get-TermWrapStatus {
    $s = @{Admin=Test-Admin}
    $s.TermsrvVersion = Get-TermsrvVersion
    $tsDll = Get-ItemProperty -Path $REG_TS -Name ServiceDll -ErrorAction SilentlyContinue
    $s.TermServiceDll = if ($tsDll) { $tsDll.ServiceDll } else { $null }
    $s.Installed = ($s.TermServiceDll -like '*TermWrap.dll')
    $umDll = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\UmRdpService\Parameters' -Name ServiceDll -ErrorAction SilentlyContinue
    $s.UmServiceDll = if ($umDll) { $umDll.ServiceDll } else { $null }
    $s.UmWrap = ($s.UmServiceDll -like '*UmWrap.dll')
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    $s.ServiceStatus = if ($svc) { $svc.Status } else { 'Missing' }
    $port = Get-ItemProperty -Path $REG_RDP_WS -Name PortNumber -ErrorAction SilentlyContinue
    $s.Port = if ($port) { $port.PortNumber } else { 3389 }
    $conn = Get-NetTCPConnection -LocalPort $s.Port -State Listen -ErrorAction SilentlyContinue
    $s.Listener = ($null -ne $conn)
    $s.WrapperLoaded = $false
    $s.LoadedModules = ''
    if ($s.ServiceStatus -eq 'Running') {
        $tsSvc = Get-CimInstance Win32_Service -Filter "Name='TermService'" -ErrorAction SilentlyContinue
        if ($tsSvc -and $tsSvc.ProcessId -gt 0) {
            try {
                $loaded = @((Get-Process -Id $tsSvc.ProcessId -Module -ErrorAction Stop | Where-Object { $_.ModuleName -match '^(TermWrap|termsrv)\.dll$' }).ModuleName | Sort-Object -Unique)
                $s.WrapperLoaded = ($loaded -contains 'TermWrap.dll' -and $loaded -contains 'termsrv.dll')
                $s.LoadedModules = ($loaded -join ',')
            } catch { $s.LoadedModules = "read error: $($_.Exception.Message)" }
        }
    }
    $s.HealthState = 'Failed'
    $s.HealthMessage = ''
    $dllPath = "$env:ProgramFiles\RDP Wrapper\TermWrap.dll"
    $s.BinaryPresent = (Test-Path $dllPath)
    if ($s.Installed) {
        if (-not $s.BinaryPresent) { $s.HealthMessage = "TermWrap.dll missing at $dllPath" }
        elseif ($s.ServiceStatus -ne 'Running') { $s.HealthMessage = "TermService $($s.ServiceStatus)" }
        elseif (-not $s.Listener) { $s.HealthMessage = 'RDP listener not listening' }
        elseif (-not $s.WrapperLoaded) { $s.HealthMessage = 'TermWrap.dll not loaded in TermService' }
        else {
            $s.Handshake = Test-RdpProtocolHandshake -Port $s.Port
            if (-not $s.Handshake) { $s.HealthMessage = 'RDP protocol handshake failed' }
            else {
                $s.HealthState = 'Healthy'
                $s.HealthMessage = 'TermWrap active and verified'
            }
        }
        if ($s.HealthState -ne 'Healthy') {
            $s.HealthState = if ($s.Listener -or $s.WrapperLoaded) { 'Degraded' } else { 'Failed' }
        }
    } else { $s.HealthMessage = "TermService ServiceDll does not point to TermWrap.dll (currently: $($s.TermServiceDll))" }
    try {
        $raw = @(qwinsta /SERVER:localhost 2>$null)
        $s.Sessions = @()
        $inData = $false
        foreach ($line in $raw) {
            if ($line -match '^\s*([\w\.\-]+)\s+(\w+)\s+(\w+)\s+(\d+)') {
                $s.Sessions += [PSCustomObject]@{User=$matches[1];ID=$matches[4];State=$matches[3]}
                $inData = $true
            } elseif ($inData -and $line -match '^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\d+)') {
                $s.Sessions += [PSCustomObject]@{User=$matches[1];ID=$matches[4];State=$matches[3]}
            }
        }
    } catch { $s.Sessions = @() }
    $wd = Get-ScheduledTask -TaskName $script:WATCHDOG_TASK -ErrorAction SilentlyContinue
    $s.Watchdog = ($null -ne $wd)
    $s.Change = Get-TermsrvChangeState
    return $s
}

function Get-TermsrvChangeState {
    $now = Get-TermsrvVersion
    $prev = $null
    if (Test-Path $script:STATE_TERMSRV) {
        try { $prev = (Get-Content $script:STATE_TERMSRV -Raw -ErrorAction Stop).Trim() } catch { }
    }
    return [PSCustomObject]@{ Current=$now; Previous=$prev; Changed=($prev -and $prev -ne $now) }
}

function Set-TermsrvChangeState {
    param([string]$Version)
    try {
        New-Item -ItemType Directory -Path $script:STATE_DIR -Force -ErrorAction Stop | Out-Null
        $Version | Out-File $script:STATE_TERMSRV -Encoding UTF8 -Force
        return $true
    } catch { return $false }
}

function Register-TermWrapWatchdog {
    param([switch]$Quiet)
    $scriptBody = @'
$l='C:\rdpwarp\watchdog.log'
New-Item 'C:\rdpwarp' -ItemType Directory -Force -EA 0|Out-Null
function w{param($m)"$(Get-Date -F 'yyyy-MM-dd HH:mm:ss') $m"|Out-File $l -Append}
$dll="$env:ProgramFiles\RDP Wrapper\TermWrap.dll"
if(!(Test-Path $dll)){w"TermWrap.dll missing";exit 0}
$svcDll=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' -Name ServiceDll -EA 0).ServiceDll
if($svcDll -notlike '*TermWrap.dll'){w"ServiceDll not pointing to TermWrap.dll";exit 0}
$svc=Get-Service TermService -EA 0
if(!$svc-or$svc.Status-ne'Running'){w"TermService not running; restarting";Restart-Service TermService -Force -EA 0;exit 0}
$p=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber -EA 0).PortNumber
if(!$p){$p=3389}
if(!(Get-NetTCPConnection -State Listen -LocalPort $p -EA 0)){w"listener down; restarting";Restart-Service TermService -Force -EA 0;exit 0}
$c=New-Object System.Net.Sockets.TcpClient
try{$h=$c.BeginConnect('127.0.0.1',$p,$null,$null);if(!$h.AsyncWaitHandle.WaitOne(2500)){w"handshake timeout; restarting";Restart-Service TermService -Force -EA 0;exit 0};$c.EndConnect($h);$st=$c.GetStream();[byte[]]$r=0x03,0x00,0x00,0x13,0x0e,0xe0,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x08,0x00,0x03,0x00,0x00,0x00;$st.Write($r,0,$r.Length);$b=New-Object byte[] 64;$n=$st.Read($b,0,64);if($n-ge11-and$b[0]-eq3){w"healthy (termsrv OK)"}else{w"handshake fail; restarting";Restart-Service TermService -Force -EA 0}}catch{w"check error: $_; restarting";Restart-Service TermService -Force -EA 0}finally{$c.Close()}
'@
    try {
        New-Item -ItemType Directory -Path (Split-Path $script:WATCHDOG_SCRIPT -Parent) -Force | Out-Null
        $scriptBody | Out-File $script:WATCHDOG_SCRIPT -Encoding ASCII -Force
        $a = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoP -W Hidden -Exec Bypass -File `"$($script:WATCHDOG_SCRIPT)`""
        $t1 = New-ScheduledTaskTrigger -AtStartup
        $t2 = New-ScheduledTaskTrigger -Daily -At 03:00
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
        Unregister-ScheduledTask -TaskName $script:WATCHDOG_TASK -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $script:WATCHDOG_TASK -Action $a -Trigger $t1,$t2 -Settings $set -User "NT AUTHORITY\SYSTEM" -RunLevel Highest -Force | Out-Null
        if (-not $Quiet) { Write-S "看门狗已注册 ($($script:WATCHDOG_TASK))" }
        return $true
    } catch {
        if (-not $Quiet) { Write-E "看门狗注册失败: $_" }
        return $false
    }
}

function Unregister-TermWrapWatchdog {
    Unregister-ScheduledTask -TaskName $script:WATCHDOG_TASK -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $script:WATCHDOG_SCRIPT) { Remove-Item $script:WATCHDOG_SCRIPT -Force -ErrorAction SilentlyContinue }
    Write-S "看门狗已注销"
}
