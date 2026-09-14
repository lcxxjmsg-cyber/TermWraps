# Core.Health.ps1 - TermWrap 健康分级 + termsrv 变化检测
# 语义重写：无 INI → 三元健康分级（Healthy / Degraded / Failed）
# 复用 rdpwarps.ps1 的：Test-RdpProtocolHandshake（握手）、会话枚举
# 无看门狗：TermWrap.dll 动态自适应 termsrv，崩溃由 SCM FailureActions 自恢复

$script:STATE_DIR = Join-Path $env:ProgramData 'termwrap'
$script:STATE_TERMSRV = Join-Path $script:STATE_DIR 'termsrv-last.txt'
$script:LEGACY_STATE_DIR = Join-Path $env:ProgramData 'rdpwarp'

function Initialize-TermWrapStateDir {
    if (-not (Test-Path -LiteralPath $script:STATE_DIR)) {
        New-Item -ItemType Directory -Path $script:STATE_DIR -Force -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($name in @('termwrap-state.json','termsrv-last.txt')) {
        $new = Join-Path $script:STATE_DIR $name
        $old = Join-Path $script:LEGACY_STATE_DIR $name
        if ((-not (Test-Path -LiteralPath $new)) -and (Test-Path -LiteralPath $old)) {
            Move-Item -LiteralPath $old -Destination $new -Force -ErrorAction SilentlyContinue
        }
    }
}

Initialize-TermWrapStateDir

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
        elseif (-not $s.Listener) {
            if ((Get-RegDword $REG_RDP fDenyTSConnections) -ne 0) {
                $s.HealthMessage = "RDP is disabled (fDenyTSConnections=1); enable Remote Desktop so TermService can bind the port-$($s.Port) listener"
            } else {
                $s.HealthMessage = 'RDP listener not listening'
            }
        }
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

# 看门狗已移除：TermWrap.dll 动态自适应 termsrv，服务崩溃由 SCM FailureActions 自恢复。
