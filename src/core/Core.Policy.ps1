# Core.Policy.ps1 - 会话/安全/显示/超时/端口/防火墙/RemoteApp（1:1 移植自 rdpwarps.ps1）

function Get-RdpFirewallRuleNames {
    param([int]$Port)
    return @("rdpwarp-RDP-TCP-$Port-In","rdpwarp-RDP-UDP-$Port-In")
}

function Add-RdpFirewallPort {
    param([int]$Port)
    if ($Port -lt 1 -or $Port -gt 65535) { return $false }
    $names = Get-RdpFirewallRuleNames $Port
    try {
        if (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -DisplayName $names[0] -ErrorAction SilentlyContinue
            Remove-NetFirewallRule -DisplayName $names[1] -ErrorAction SilentlyContinue
            New-NetFirewallRule -DisplayName $names[0] -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
            New-NetFirewallRule -DisplayName $names[1] -Direction Inbound -Action Allow -Protocol UDP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
            $tcp = Get-NetFirewallRule -DisplayName $names[0] -ErrorAction Stop
            $udp = Get-NetFirewallRule -DisplayName $names[1] -ErrorAction Stop
            $tcpFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $tcp -ErrorAction Stop
            $udpFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $udp -ErrorAction Stop
            return ($tcp.Enabled -eq 'True' -and $udp.Enabled -eq 'True' -and
                [string]$tcpFilter.LocalPort -eq [string]$Port -and [string]$tcpFilter.Protocol -eq 'TCP' -and
                [string]$udpFilter.LocalPort -eq [string]$Port -and [string]$udpFilter.Protocol -eq 'UDP')
        }
        & netsh advfirewall firewall delete rule name="$($names[0])" 2>$null | Out-Null
        & netsh advfirewall firewall delete rule name="$($names[1])" 2>$null | Out-Null
        & netsh advfirewall firewall add rule name="$($names[0])" dir=in protocol=tcp localport=$Port profile=any action=allow 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        & netsh advfirewall firewall add rule name="$($names[1])" dir=in protocol=udp localport=$Port profile=any action=allow 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch { Write-W "Firewall rule creation failed for port $Port`: $_"; return $false }
}

function Remove-RdpFirewallPort {
    param([int]$Port)
    $names = Get-RdpFirewallRuleNames $Port
    if (Get-Command Remove-NetFirewallRule -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $names[0] -ErrorAction SilentlyContinue
        Remove-NetFirewallRule -DisplayName $names[1] -ErrorAction SilentlyContinue
    } else {
        & netsh advfirewall firewall delete rule name="$($names[0])" 2>$null | Out-Null
        & netsh advfirewall firewall delete rule name="$($names[1])" 2>$null | Out-Null
    }
}

function Test-RdpHostCapability {
    $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    $nativeUnsupported = @('Core','CoreSingleLanguage','CoreCountrySpecific','Starter') -contains $edition
    $checks = [ordered]@{
        TermsrvDll = Test-Path "$env:SystemRoot\System32\termsrv.dll"
        TermService = $null -ne (Get-Service TermService -ErrorAction SilentlyContinue)
        RdpTcpRegistry = Test-Path $REG_RDP_WS
    }
    $missing = @($checks.Keys | Where-Object { -not $checks[$_] })
    return [PSCustomObject]@{
        CanInstall = $missing.Count -eq 0
        NativeHostSupported = -not $nativeUnsupported
        Edition = $edition
        Missing = $missing
        Message = if ($missing.Count) { "Missing RDP components: $($missing -join ', ')" } elseif ($nativeUnsupported) { "Windows edition $edition has no native RDP host; RDP Wrapper support is required" } else { "Native RDP host components detected ($edition)" }
    }
}

function Test-RdpTcpRegistryHealth {
    $result = [ordered]@{Healthy=$true;Port=$null;Missing=@();Message=''}
    if (-not (Test-Path -LiteralPath $REG_RDP_WS)) {
        $result.Healthy = $false
        $result.Missing = @('RDP-Tcp registry key')
    } else {
        $properties = Get-ItemProperty -LiteralPath $REG_RDP_WS -ErrorAction SilentlyContinue
        $port = 0
        if ($properties) { [void][int]::TryParse([string]$properties.PortNumber,[ref]$port) }
        if ($port -lt 1 -or $port -gt 65535) { $result.Missing += 'PortNumber' } else { $result.Port = $port }
        if ($null -eq $properties.fEnableWinStation) { $result.Missing += 'fEnableWinStation' }
        if ([string]::IsNullOrWhiteSpace([string]$properties.WdName)) { $result.Missing += 'WdName' }
        # NOTE: WinStationName must NOT be required here. Windows does not create
        # it under ...\WinStations\RDP-Tcp by default (fresh Win10/11 keys lack
        # it), so requiring it blocks clean installations. A listener key stripped
        # by an old uninstall is still caught by the key, PortNumber,
        # fEnableWinStation and WdName checks above.
        if ($result.Missing.Count -gt 0) { $result.Healthy = $false }
    }
    $result.Message = if ($result.Healthy) {
        "Native RDP-Tcp listener configuration is complete (port $($result.Port))"
    } else {
        "Native RDP-Tcp listener configuration is incomplete: $($result.Missing -join ', ')"
    }
    return [PSCustomObject]$result
}

function Enable-RdpHostAccess {
    param([int]$Port=3389)
    if (-not (Set-RegDword $REG_RDP fDenyTSConnections 0)) { throw 'Failed to enable Remote Desktop in the registry' }
    $svc = Get-Service TermService -ErrorAction SilentlyContinue
    if ($svc -and $svc.StartType -eq 'Disabled') { Set-Service TermService -StartupType Manual -ErrorAction SilentlyContinue }
    if (-not (Add-RdpFirewallPort $Port)) { throw "Failed to create validated TCP/UDP firewall rules for RDP port $Port" }
    $deny = Get-RegDword $REG_RDP fDenyTSConnections
    if ($deny -ne 0) { throw 'Remote Desktop remained disabled after registry update' }
    return $true
}

function Enable-Rdp60FpsLimit {
    $winStations = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations'
    if (-not (Set-RegDword $winStations DWMFRAMEINTERVAL 15)) { return $false }
    return (Get-RegDword $winStations DWMFRAMEINTERVAL) -eq 15
}

function Add-RdpwrapDefenderExclusions {
    $addMp = Get-Command Add-MpPreference -ErrorAction SilentlyContinue
    if (-not $addMp) { return }
    $paths = @(
        $script:RDPWRAP_DIR,
        'C:\rdpwarp',
        $script:FALLBACK_DIR,
        "$env:ProgramFiles\RDP Wrapper"
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($path in $paths) {
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-S "Defender exclusion: $path"
        } catch {
            Write-W "Defender exclusion failed: $path ($($_.Exception.Message))"
        }
    }
}

function Set-RdpPort {
    if (-not (Test-Admin)) { Write-E "$(T 'admin_required')"; Write-Host ""; cmd /c pause 2>&1 | Out-Null; return }
    $s = Get-TermWrapStatus
    Show-ConfigMenu (T 'menu_port_title') @("$(T 'menu_port_cur'): $($s.Port)","-","$(T 'menu_port_prompt')")
    $p = Read-Host "> "
    if ($p -match '^\d+$' -and [int]$p -ge 1024 -and [int]$p -le 65535) {
        $port = [int]$p
        $oldPort = [int]$s.Port
        if ($port -eq $oldPort) { Write-S "RDP is already configured for port $port"; Write-Host ""; cmd /c pause 2>&1 | Out-Null; return }
        if ($env:SESSIONNAME -match '^RDP-') {
            Write-E 'Changing and restarting the RDP listener from an active RDP session is unsafe. Run this option from the local console.'
            Write-Host ""; cmd /c pause 2>&1 | Out-Null; return
        }
        $tcpConflict = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
        $udpConflict = Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue
        if ($tcpConflict -or $udpConflict) { Write-E "Port $port is already in use"; Write-Host ""; cmd /c pause 2>&1 | Out-Null; return }
        if (-not (Add-RdpFirewallPort $port)) { Write-E "Failed to open TCP/UDP firewall rules for port $port"; Write-Host ""; cmd /c pause 2>&1 | Out-Null; return }
        Set-RegDword $REG_RDP_WS PortNumber $port | Out-Null
        $readback = Get-ItemProperty -Path $REG_RDP_WS -Name PortNumber -ErrorAction SilentlyContinue
        if (-not $readback -or $readback.PortNumber -ne $port) {
            Remove-RdpFirewallPort $port
            Write-E "Failed to write port to registry"; Write-Host ""; cmd /c pause 2>&1 | Out-Null; return
        }
        Restart-RdpService
        $listenerReady = $false
        for ($attempt=0; $attempt -lt 10; $attempt++) {
            if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { $listenerReady = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if ($listenerReady -and -not (Test-RdpProtocolHandshake -Port $port)) {
            Write-W "A TCP listener appeared on $port, but it did not complete an RDP protocol handshake"
            $listenerReady = $false
        }
        if (-not $listenerReady) {
            Write-W "No listener appeared on $port; rolling back to $oldPort"
            Set-RegDword $REG_RDP_WS PortNumber $oldPort | Out-Null
            Add-RdpFirewallPort $oldPort | Out-Null
            Restart-RdpService
            Remove-RdpFirewallPort $port
            Write-E "Port change failed and was rolled back to $oldPort"
            Write-Host ""; cmd /c pause 2>&1 | Out-Null; return
        }
        Remove-RdpFirewallPort $oldPort
        Write-S "$(T 'menu_port_done') $($env:COMPUTERNAME):$port"
        Write-S "TCP/UDP firewall rules migrated from $oldPort to $port and the RDP protocol handshake was verified"
    } else { Write-W "Invalid port. Use a value from 1024 to 65535." }
    Write-Host ""; cmd /c pause 2>&1 | Out-Null
}

function Set-RdpSessions {
    do {
        $s = Get-RegDword $REG_POLICY "MaxInstanceCount"
        $sspu = Get-RegDword $REG_POLICY "fSingleSessionPerUser"
        Show-ConfigMenu (T 'menu_session_title') @(
            @{Label=(T 'menu_session_s');Value=if($null -ne $s){$s}else{(T 'unlimited')}}
            @{Label=(T 'menu_session_u');Value=if($sspu -eq 1){T 'on'}elseif($sspu -eq 0){T 'off'}else{T 'dflt'}}
            "-"
            @{Label="1. $(T 'menu_session_m')"}
            @{Label="2. $(T 'menu_session_t')"}
            @{Label="3. $(T 'menu_session_r')"}
        )
        $c = Read-Host "> "
        switch ($c) {
            "1" { Write-I "$(T 'menu_session_m') (0=$(T 'unlimited')):" -NoNewline; $v = Read-Host; if ($v -match '^\d+$') { Set-RegDword $REG_POLICY MaxInstanceCount [int]$v } }
            "2" { $cur = Get-RegDword $REG_POLICY fSingleSessionPerUser; Set-RegDword $REG_POLICY fSingleSessionPerUser $(if($cur -eq 1){0}else{1}) }
            "3" { Remove-Item "$REG_POLICY\MaxInstanceCount" -Force -EA 0; Remove-Item "$REG_POLICY\fSingleSessionPerUser" -Force -EA 0 }
            default { if ($c -ne '0') { Write-W "$(T 'inv_opt')"; Start-Sleep -Milliseconds 800 } }
        }
        if ($c -eq '1' -or $c -eq '2' -or $c -eq '3') { Restart-RdpService }
    } while ($c -ne '0')
}

function Set-RdpSecurity {
    do {
        $nla = Get-RegDword $REG_RDP_WS "UserAuthentication"
        $sl = Get-RegDword $REG_RDP_WS "SecurityLayer"
        $nlaStr = if ($nla -eq 1) { T 'on' } elseif ($nla -eq 0) { T 'off' } else { T 'dflt' }
        $slStr = @{0="RDP";1="Negotiate";2="TLS"}[[int]$sl]
        Show-ConfigMenu (T 'menu_security_title') @(
            @{Label=(T 'menu_security_nla');Value=$nlaStr}
            @{Label=(T 'menu_security_sl');Value=$slStr}
            "-"
            @{Label="1. $(T 'menu_security_tn')"}
            @{Label="2. $(T 'menu_security_ss')"}
        )
        $c = Read-Host "> "
        switch ($c) {
            "1" { $cur = Get-RegDword $REG_RDP_WS UserAuthentication; Set-RegDword $REG_RDP_WS UserAuthentication $(if($cur -eq 1){0}else{1}) }
            "2" { Write-I "$(T 'menu_security_ss'): 0=RDP 1=Negotiate 2=TLS:" -NoNewline; $v = Read-Host; if($v -match '^[0-2]$'){Set-RegDword $REG_RDP_WS SecurityLayer [int]$v} }
            default { if ($c -ne '0') { Write-W "$(T 'inv_opt')"; Start-Sleep -Milliseconds 800 } }
        }
        if ($c -eq '1' -or $c -eq '2') { Restart-RdpService }
    } while ($c -ne '0')
}

function Set-RdpDisplay {
    do {
        $hide = Get-RegDword $REG_WINLOGON "HideConsoleUsers"
        Show-ConfigMenu (T 'menu_display_title') @(
            @{Label=(T 'menu_display_mm');Value=if((Get-RegDword $REG_POLICY "fEnableRemoteFX")-eq1){T 'on'}else{T 'dflt'}}
            @{Label=(T 'menu_display_hide');Value=if($hide -eq 1){T 'on'}else{T 'off'}}
            @{Label=(T 'menu_display_ar');Value=if((Get-RegDword $REG_POLICY "fDisableAutoReconnect")-eq1){T 'off'}else{T 'dflt'}}
            "-"
            @{Label="1. $(T 'menu_display_tm')"}
            @{Label="2. $(T 'menu_display_th')"}
            @{Label="3. $(T 'menu_display_ta')"}
        )
        $c = Read-Host "> "
        switch ($c) {
            "1" { $cur = Get-RegDword $REG_POLICY fEnableRemoteFX; Set-RegDword $REG_POLICY fEnableRemoteFX $(if($cur -eq 1){0}else{1}) }
            "2" { $cur = Get-RegDword $REG_WINLOGON HideConsoleUsers; Set-RegDword $REG_WINLOGON HideConsoleUsers $(if($cur -eq 1){0}else{1}) }
            "3" { $cur = Get-RegDword $REG_POLICY fDisableAutoReconnect; Set-RegDword $REG_POLICY fDisableAutoReconnect $(if($cur -eq 1){0}else{1}) }
            default { if ($c -ne '0') { Write-W "$(T 'inv_opt')"; Start-Sleep -Milliseconds 800 } }
        }
        if ($c -eq '1' -or $c -eq '2' -or $c -eq '3') { Restart-RdpService }
    } while ($c -ne '0')
}

function Set-RdpTimeouts {
    do {
        $disc = Get-RegDword $REG_POLICY "MaxDisconnectionTime"
        $idle = Get-RegDword $REG_POLICY "MaxIdleTime"
        $sess = Get-RegDword $REG_POLICY "MaxSessionTime"
        $discStr = if ($disc -and $disc -ne 0) { "$($disc/60000)$(T 'min')" } else { T 'never' }
        $idleStr = if ($idle -and $idle -ne 0) { "$($idle/60000)$(T 'min')" } else { T 'never' }
        $sessStr = if ($sess -and $sess -ne 0) { "$($sess/60000)$(T 'min')" } else { T 'never' }
        Show-ConfigMenu (T 'menu_timeout_title') @(
            @{Label=(T 'menu_timeout_disc');Value=$discStr}
            @{Label=(T 'menu_timeout_idle');Value=$idleStr}
            @{Label=(T 'menu_timeout_active');Value=$sessStr}
            "-"
            @{Label="1. $(T 'menu_timeout_sd')"}
            @{Label="2. $(T 'menu_timeout_si')"}
            @{Label="3. $(T 'menu_timeout_sa')"}
            @{Label="4. $(T 'menu_timeout_reset')"}
        )
        $c = Read-Host "> "
        $matched = $false
        switch -Regex ($c) {
            "^1$" { Write-I "$(T 'menu_timeout_sd') (0=$(T 'never')):" -NoNewline; $v=Read-Host; if($v-match'^\d+$'){Set-RegDword $REG_POLICY MaxDisconnectionTime ([int]$v*60000)}; $matched=$true }
            "^2$" { Write-I "$(T 'menu_timeout_si') (0=$(T 'never')):" -NoNewline; $v=Read-Host; if($v-match'^\d+$'){Set-RegDword $REG_POLICY MaxIdleTime ([int]$v*60000)}; $matched=$true }
            "^3$" { Write-I "$(T 'menu_timeout_sa') (0=$(T 'never')):" -NoNewline; $v=Read-Host; if($v-match'^\d+$'){Set-RegDword $REG_POLICY MaxSessionTime ([int]$v*60000)}; $matched=$true }
            "^4$" { Set-RegDword $REG_POLICY MaxDisconnectionTime 0;Set-RegDword $REG_POLICY MaxIdleTime 0;Set-RegDword $REG_POLICY MaxSessionTime 0; $matched=$true }
        }
        if (-not $matched -and $c -ne '0') { Write-W "$(T 'inv_opt')"; Start-Sleep -Milliseconds 800 }
        if ($matched) { Restart-RdpService }
    } while ($c -ne '0')
}

function New-RemoteAppFile {
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  $(T 'remoteapp_header')" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan

    $server = Read-Host "$(T 'remoteapp_server')"
    if (-not $server) { Write-W "$(T 'cancel')"; return }

    Write-Host "`n$(T 'remoteapp_presets'):" -ForegroundColor White
    $presets = @("cmd.exe","explorer.exe","iexplore.exe","notepad.exe","powershell.exe","$(T 'remoteapp_custom')")
    for ($i = 0; $i -lt $presets.Count; $i++) {
        Write-Host "  $($i+1). $($presets[$i])" -ForegroundColor Yellow
    }
    $pc = Read-Host "> $(T 'sel_opt')"
    $program = ""
    if ($pc -match '^[1-5]$') {
        $program = "C:\Windows\System32\$($presets[[int]$pc-1])"
    } elseif ($pc -eq '6') {
        $program = Read-Host "$(T 'remoteapp_custom')"
    } else { Write-W "$(T 'inv_opt')"; return }
    if (-not $program) { Write-W "$(T 'cancel')"; return }

    $name = Read-Host "$(T 'remoteapp_name') ($([System.IO.Path]::GetFileNameWithoutExtension($program)))"
    if (-not $name) { $name = [System.IO.Path]::GetFileNameWithoutExtension($program) }

    $args = Read-Host "$(T 'remoteapp_args')"

    Write-Host "`n$(T 'remoteapp_optional'):" -ForegroundColor White
    $clip = Read-Host "$(T 'remoteapp_clipboard') (Y/n)"
    $clip = if ($clip -eq 'n' -or $clip -eq 'N') { 0 } else { 1 }
    $drv = Read-Host "$(T 'remoteapp_drives') (Y/n)"
    $drv = if ($drv -eq 'n' -or $drv -eq 'N') { 0 } else { 1 }
    $audio = Read-Host "$(T 'remoteapp_audio') (0)"
    if ($audio -notmatch '^[0-2]$') { $audio = '0' }

    $width = Read-Host "Desktop width (default 1024)"
    if (-not $width -or $width -notmatch '^\d+$') { $width = '1024' }
    $height = Read-Host "Desktop height (default 768)"
    if (-not $height -or $height -notmatch '^\d+$') { $height = '768' }

    $username = Read-Host "$(T 'remoteapp_username')"

    $desktop = [Environment]::GetFolderPath('Desktop')
    $filename = "$desktop\$name.rdp"
    $content = @"
remoteapplicationmode:i:1
remoteapplicationprogram:s:$program
remoteapplicationname:s:$name
remoteapplicationcmdline:s:$args
full address:s:$server
promptcredentialonce:i:1
authentication level:i:0
session bpp:i:32
desktopwidth:i:$width
desktopheight:i:$height
redirectclipboard:i:$clip
redirectprinters:i:0
redirectcomports:i:0
redirectsmartcards:i:0
redirectdrives:i:$drv
audiomode:i:$audio
connection type:i:2
networkautodetect:i:1
"@
    if ($username) { $content += "username:s:$username`r`n" }
    $content | Out-File $filename -Encoding ASCII
    Write-S "$(T 'remoteapp_done') $filename"
    Write-Host ""; cmd /c pause 2>&1 | Out-Null
}
