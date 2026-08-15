# Core.Shadow.ps1 - 影子/远程控制（1:1 移植自 rdpwarps.ps1）

function Get-ShadowUi {
    $u = $script:SHADOW_UI[$script:LANG]
    if (-not $u) { $u = $script:SHADOW_UI['en'] }
    return $u
}

function S($k, $f = @()) {
    $v = (Get-ShadowUi)[$k]
    if (-not $v) { $v = $script:SHADOW_UI['en'][$k] }
    if (-not $v) { return $k }
    for ($i = 0; $i -lt $f.Count; $i++) { $v = $v.Replace("{$i}", [string]$f[$i]) }
    return $v
}

function Get-ShadowModeMap {
    return @{0=(T 'menu_shadow_off');1=(T 'menu_shadow_fwp');2=(T 'menu_shadow_fwo');3=(T 'menu_shadow_vwp');4=(T 'menu_shadow_vwo')}
}

function Format-ShadowValue {
    param($Value,[hashtable]$Map,[string]$NotConfigured)
    try {
        if ($null -ne $Value -and $Map.ContainsKey([int]$Value)) { return "$Value = $($Map[[int]$Value])" }
    } catch { }
    return $NotConfigured
}

function Get-ShadowUsers {
    $users = @()
    try {
        if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
            $users = @(Get-LocalUser -ErrorAction Stop)
        }
    } catch { $users = @() }
    if ($users.Count -eq 0) {
        try { $users = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop) } catch { $users = @() }
    }
    $exclude = @('DefaultAccount','WDAGUtilityAccount')
    $result = @()
    foreach ($u in $users) {
        $name = if ($u.PSObject.Properties['Name']) { [string]$u.Name } else { '' }
        if (-not $name -or $exclude -contains $name) { continue }
        $sid = if ($u.PSObject.Properties['SID']) { [string]$u.SID } elseif ($u.PSObject.Properties['Sid']) { [string]$u.Sid } else { '' }
        if (-not $sid -or -not $sid.StartsWith('S-1-5')) { continue }
        $result += [PSCustomObject]@{ Name=$name; Sid=$sid }
    }
    return @($result | Sort-Object Name)
}

function Get-ShadowUserValue {
    param([string]$Sid)
    $ts = 'SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    try {
        if ([Microsoft.Win32.Registry]::Users.GetSubKeyNames() -contains $Sid) {
            $k = [Microsoft.Win32.Registry]::Users.OpenSubKey("$Sid\$ts")
            if (-not $k) { return $null }
            try { return $k.GetValue('Shadow', $null) } finally { $k.Close() }
        }
        $profile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profile) { return $null }
        $ntuser = Join-Path $profile 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $ntuser -ErrorAction SilentlyContinue)) { return $null }
        $mount = "rdpwarp_shadow_$Sid"
        & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
        & reg.exe load "HKU\$mount" $ntuser 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        try {
            $k = [Microsoft.Win32.Registry]::Users.OpenSubKey("$mount\$ts")
            if (-not $k) { return $null }
            try { return $k.GetValue('Shadow', $null) } finally { $k.Close() }
        } finally { & reg.exe unload "HKU\$mount" 2>&1 | Out-Null }
    } catch { return $null }
}

function Set-ShadowUserValue {
    param([string]$Sid,[int]$Value,[switch]$Clear)
    $ts = 'SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $mount = ''
    try {
        if ([Microsoft.Win32.Registry]::Users.GetSubKeyNames() -contains $Sid) {
            $root = $Sid
        } else {
            $profile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            if (-not $profile) { return $null }
            $ntuser = Join-Path $profile 'NTUSER.DAT'
            if (-not (Test-Path -LiteralPath $ntuser -ErrorAction SilentlyContinue)) { return $null }
            $mount = "rdpwarp_shadow_$Sid"
            & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
            & reg.exe load "HKU\$mount" $ntuser 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return $null }
            $root = $mount
        }
        $k = [Microsoft.Win32.Registry]::Users.CreateSubKey("$root\$ts")
        try {
            if ($Clear) {
                if ($k.GetValueNames() -contains 'Shadow') { $k.DeleteValue('Shadow', $false) }
                return ($k.GetValueNames() -notcontains 'Shadow')
            }
            $k.SetValue('Shadow', $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
            return ([int]$k.GetValue('Shadow', -1) -eq $Value)
        } finally { $k.Close() }
    } catch { return $false } finally {
        if ($mount) { & reg.exe unload "HKU\$mount" 2>&1 | Out-Null }
    }
}

function Get-ShadowGlobal {
    $policy = Get-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'Shadow'
    $legacy = Get-RegDword $REG_POLICY_LOCAL 'Shadow'
    $eff = $policy
    if ($null -eq $eff) { $eff = $legacy }
    return [PSCustomObject]@{ Policy = $policy; Legacy = $legacy; Effective = $eff }
}

function Set-ShadowGlobal {
    param([int]$Value,[switch]$Clear)
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    if ($Clear) {
        Remove-ItemProperty -LiteralPath $policy -Name 'Shadow' -ErrorAction SilentlyContinue
        return ($null -eq (Get-RegDword $policy 'Shadow'))
    }
    if (-not (Set-RegDword $policy 'Shadow' $Value)) { return $false }
    return ((Get-RegDword $policy 'Shadow') -eq $Value)
}

function Set-ShadowGlobalMenu {
    $su = Get-ShadowUi
    $sv = Get-ShadowModeMap
    do {
        $g = Get-ShadowGlobal
        Show-ConfigMenu (S 'global') @(
            @{Label=(S 'cur');Value=(Format-ShadowValue -Value $g.Policy -Map $sv -NotConfigured $su.notcfg)}
            @{Label=(S 'eff');Value=(Format-ShadowValue -Value $g.Effective -Map $sv -NotConfigured $su.notcfg)}
            @{Label=(S 'legacy');Value=(Format-ShadowValue -Value $g.Legacy -Map $sv -NotConfigured $su.notcfg)}
            "-"
            @{Label="1. $(T 'menu_shadow_off')"}
            @{Label="2. $(T 'menu_shadow_fwp')"}
            @{Label="3. $(T 'menu_shadow_fwo')"}
            @{Label="4. $(T 'menu_shadow_vwp')"}
            @{Label="5. $(T 'menu_shadow_vwo')"}
            @{Label="6. $(S 'clear_global')"}
            @{Label="7. $(S 'clear_legacy')"}
        )
        $c = Read-Host "> "
        switch -Regex ($c) {
            '^[1-5]$' { if (Set-ShadowGlobal -Value ([int]$c - 1)) { Write-S (S 'apply' @((S 'global'), $sv[([int]$c - 1)])); Write-I $su.apply_note } else { Write-E (S 'err_write' @((S 'global'))) } }
            '^6$' { if (Set-ShadowGlobal -Clear) { Write-S $su.gclear } else { Write-E (S 'err_write' @((S 'global'))) } }
            '^7$' { Remove-ItemProperty -LiteralPath $REG_POLICY_LOCAL -Name 'Shadow' -ErrorAction SilentlyContinue; Write-S $su.legcleared }
            '^0$' { }
            default { Write-W (T 'inv_opt'); Start-Sleep -Milliseconds 800 }
        }
    } while ($c -ne '0')
}

function Set-ShadowUserMenu {
    $su = Get-ShadowUi
    $sv = Get-ShadowModeMap
    $users = Get-ShadowUsers
    if ($users.Count -eq 0) { Write-W $su.nousers; Start-Sleep -Milliseconds 800; return }
    $target = $null
    $exit = $false
    do {
        Clear-Host
        Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "|  $(S 'seluser')" -ForegroundColor Cyan
        Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
        for ($i = 0; $i -lt $users.Count; $i++) {
            $cur = Get-ShadowUserValue -Sid $users[$i].Sid
            $v = Format-ShadowValue -Value $cur -Map $sv -NotConfigured $su.notcfg
            Write-Host "|  $($i+1). $($users[$i].Name.PadRight(20)) [$v]" -ForegroundColor Yellow
        }
        Write-Host "|  0. $(T 'back_main')" -ForegroundColor Green
        Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
        $c = Read-Host "> "
        if ($c -eq '0') { $exit = $true }
        elseif ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $users.Count) { $target = $users[([int]$c - 1)] }
        else { Write-W (T 'inv_opt'); Start-Sleep -Milliseconds 800 }
    } while (-not $exit -and -not $target)
    if (-not $target) { return }

    do {
        $cur = Get-ShadowUserValue -Sid $target.Sid
        Show-ConfigMenu "$(S 'user'): $($target.Name)" @(
            @{Label=(S 'cur');Value=(Format-ShadowValue -Value $cur -Map $sv -NotConfigured $su.notcfg)}
            "-"
            @{Label="1. $(T 'menu_shadow_off')"}
            @{Label="2. $(T 'menu_shadow_fwp')"}
            @{Label="3. $(T 'menu_shadow_fwo')"}
            @{Label="4. $(T 'menu_shadow_vwp')"}
            @{Label="5. $(T 'menu_shadow_vwo')"}
            @{Label="6. $(S 'clear_global')"}
        )
        $c = Read-Host "> "
        switch -Regex ($c) {
            '^[1-5]$' {
                $r = Set-ShadowUserValue -Sid $target.Sid -Value ([int]$c - 1)
                if ($r -eq $true) { Write-S (S 'apply' @($target.Name, $sv[([int]$c - 1)])); Write-I $su.apply_note }
                elseif ($r -eq $false) { Write-E (S 'err_write' @($target.Name)) }
                else { Write-E (S 'err_hive' @($target.Name)) }
            }
            '^6$' {
                $r = Set-ShadowUserValue -Sid $target.Sid -Clear
                if ($r -eq $true) { Write-S (S 'cleared' @($target.Name)) }
                elseif ($r -eq $false) { Write-E (S 'err_write' @($target.Name)) }
                else { Write-E (S 'err_hive' @($target.Name)) }
            }
            '^0$' { }
            default { Write-W (T 'inv_opt'); Start-Sleep -Milliseconds 800 }
        }
    } while ($c -ne '0')
}

function Set-RdpShadowing {
    do {
        $su = Get-ShadowUi
        $sv = Get-ShadowModeMap
        $g = Get-ShadowGlobal
        $users = Get-ShadowUsers
        Clear-Host
        Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "|  $(T 'menu_shadow_title')" -ForegroundColor Cyan
        Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "|  $(S 'global'): " -NoNewline -ForegroundColor White
        Write-Host (Format-ShadowValue -Value $g.Policy -Map $sv -NotConfigured $su.notcfg) -ForegroundColor DarkGray
        Write-Host "|  $(S 'legacy'): " -NoNewline -ForegroundColor DarkGray
        Write-Host (Format-ShadowValue -Value $g.Legacy -Map $sv -NotConfigured $su.notcfg) -ForegroundColor DarkGray
        Write-Host "|  $(S 'note')" -ForegroundColor DarkGray
        Write-Host "|  $(S 'user'):" -ForegroundColor White
        foreach ($u in $users) {
            $uv = Get-ShadowUserValue -Sid $u.Sid
            $line = "    $($u.Name.PadRight(22)) $(Format-ShadowValue -Value $uv -Map $sv -NotConfigured $su.notcfg)"
            if ($null -eq $uv -and $null -ne $g.Effective) { $line += "   ->  $(Format-ShadowValue -Value $g.Effective -Map $sv -NotConfigured $su.notcfg)" }
            Write-Host "|$line" -ForegroundColor DarkGray
        }
        Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "|  1. $(S 'global')" -ForegroundColor Yellow
        Write-Host "|  2. $(S 'user')" -ForegroundColor Yellow
        Write-Host "|  0. $(T 'back_main')" -ForegroundColor Green
        Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
        $c = Read-Host "> "
        switch ($c) {
            "1" { Set-ShadowGlobalMenu }
            "2" { Set-ShadowUserMenu }
            default { if ($c -ne '0') { Write-W (T 'inv_opt'); Start-Sleep -Milliseconds 800 } }
        }
    } while ($c -ne '0')
}
