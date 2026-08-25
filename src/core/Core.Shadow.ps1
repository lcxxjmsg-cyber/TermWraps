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
    # 同时写 RDP-Tcp 监听器本地值：这才是真正对 RDP 连接生效的影子级别（本地遗留）。
    # 只写组策略键会导致"改了没效果"，故需一并写入并重启 TermService 使监听器重读。
    if ($Clear) {
        Remove-ItemProperty -LiteralPath $policy -Name 'Shadow' -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $REG_POLICY_LOCAL -Name 'Shadow' -ErrorAction SilentlyContinue
        $ok = ($null -eq (Get-RegDword $policy 'Shadow')) -and ($null -eq (Get-RegDword $REG_POLICY_LOCAL 'Shadow'))
    } else {
        if (-not (Set-RegDword $policy 'Shadow' $Value)) { return $false }
        Set-RegDword $REG_POLICY_LOCAL 'Shadow' $Value | Out-Null
        if ((Get-RegDword $policy 'Shadow') -ne $Value) { return $false }
        $ok = ((Get-RegDword $REG_POLICY_LOCAL 'Shadow') -eq $Value)
    }
    Restart-RdpService
    return $ok
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
            @{Label=(T 'menu_shadow_off')}
            @{Label=(T 'menu_shadow_fwp')}
            @{Label=(T 'menu_shadow_fwo')}
            @{Label=(T 'menu_shadow_vwp')}
            @{Label=(T 'menu_shadow_vwo')}
            @{Label=(S 'clear_global')}
            @{Label=(S 'clear_legacy')}
        )
        $c = Read-Host "> "
        switch -Regex ($c) {
            '^[1-5]$' { if (Set-ShadowGlobal -Value ([int]$c - 1)) { Write-S (S 'apply' @((S 'global'), $sv[([int]$c - 1)])); Write-I $su.apply_note } else { Write-E (S 'err_write' @((S 'global'))) } }
            '^6$' { if (Set-ShadowGlobal -Clear) { Write-S $su.gclear } else { Write-E (S 'err_write' @((S 'global'))) } }
            '^7$' { Remove-ItemProperty -LiteralPath $REG_POLICY_LOCAL -Name 'Shadow' -ErrorAction SilentlyContinue; Restart-RdpService; Write-S $su.legcleared }
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
            @{Label=(T 'menu_shadow_off')}
            @{Label=(T 'menu_shadow_fwp')}
            @{Label=(T 'menu_shadow_fwo')}
            @{Label=(T 'menu_shadow_vwp')}
            @{Label=(T 'menu_shadow_vwo')}
            @{Label=(S 'clear_global')}
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

# SHADOW_UI 8 语言表（1:1 移植）
$script:SHADOW_UI = @{
    zh = @{ global='全局策略'; user='用户级策略'; notcfg='未配置'; eff='生效值'; legacy='本地遗留 (RDP-Tcp)'; note='用户级策略优先于全局策略'; cur='当前值'; seluser='选择要设置的用户'; nousers='未找到本地用户'; apply='已应用：{0} = {1}'; cleared='已清除：{0}'; clear_global='清除（未配置）'; clear_legacy='清除本地遗留值 (RDP-Tcp)'; gclear='全局策略已清除'; legcleared='本地遗留值已清除'; err_hive='无法访问 {0} 的配置文件（可能未登录过或权限不足）'; err_write='写入验证失败：{0}'; apply_note='对用户的新会话生效；已登录会话需注销重登' }
    en = @{ global='Global Policy'; user='Per-User Policy'; notcfg='Not Configured'; eff='Effective'; legacy='Legacy Local (RDP-Tcp)'; note='Per-user policy overrides global policy'; cur='Current value'; seluser='Select a user to configure'; nousers='No local users found'; apply='Applied: {0} = {1}'; cleared='Cleared: {0}'; clear_global='Clear (Not Configured)'; clear_legacy='Clear legacy local value (RDP-Tcp)'; gclear='Global policy cleared'; legcleared='Legacy local value cleared'; err_hive='Cannot access the profile for {0} (never logged in or insufficient permission)'; err_write='Write verification failed: {0}'; apply_note='Takes effect for new sessions; logged-on sessions need a re-logon' }
    ja = @{ global='グローバルポリシー'; user='ユーザー別ポリシー'; notcfg='未設定'; eff='有効値'; legacy='ローカル残存 (RDP-Tcp)'; note='ユーザー別ポリシーはグローバルポリシーより優先されます'; cur='現在の値'; seluser='設定するユーザーを選択'; nousers='ローカルユーザーが見つかりません'; apply='適用しました：{0} = {1}'; cleared='クリアしました：{0}'; clear_global='クリア（未設定）'; clear_legacy='ローカル残存値をクリア (RDP-Tcp)'; gclear='グローバルポリシーをクリアしました'; legcleared='ローカル残存値をクリアしました'; err_hive='{0} のプロファイルにアクセスできません（未ログオンまたは権限不足）'; err_write='書き込み検証に失敗：{0}'; apply_note='新しいセッションに適用されます。ログオン中のセッションは再ログオンが必要です' }
    ko = @{ global='글로벌 정책'; user='사용자별 정책'; notcfg='미설정'; eff='적용 값'; legacy='로컬 레거시 (RDP-Tcp)'; note='사용자별 정책이 글로벌 정책보다 우선합니다'; cur='현재 값'; seluser='설정할 사용자 선택'; nousers='로컬 사용자를 찾을 수 없습니다'; apply='적용됨: {0} = {1}'; cleared='해제됨: {0}'; clear_global='해제 (미설정)'; clear_legacy='로컬 레거시 값 해제 (RDP-Tcp)'; gclear='글로벌 정책이 해제되었습니다'; legcleared='로컬 레거시 값이 해제되었습니다'; err_hive='{0}의 프로필에 접근할 수 없습니다 (로그인 이력 없음 또는 권한 부족)'; err_write='쓰기 검증 실패: {0}'; apply_note='새 세션부터 적용됩니다. 로그인 중인 세션은 다시 로그인해야 합니다' }
    fr = @{ global='Politique globale'; user='Politique par utilisateur'; notcfg='Non configuré'; eff='Valeur effective'; legacy='Héritage local (RDP-Tcp)'; note='La politique utilisateur prime sur la politique globale'; cur='Valeur actuelle'; seluser='Choisir un utilisateur à configurer'; nousers='Aucun utilisateur local trouvé'; apply='Appliqué : {0} = {1}'; cleared='Effacé : {0}'; clear_global='Effacer (non configuré)'; clear_legacy='Effacer la valeur héritée locale (RDP-Tcp)'; gclear='Politique globale effacée'; legcleared='Valeur héritée locale effacée'; err_hive='Impossible d''accéder au profil de {0} (jamais connecté ou permissions insuffisantes)'; err_write='Échec de vérification de l''écriture : {0}'; apply_note='Effectif pour les nouvelles sessions ; une reconnexion est requise pour les sessions actives' }
    de = @{ global='Globale Richtlinie'; user='Richtlinie pro Benutzer'; notcfg='Nicht konfiguriert'; eff='Effektiv'; legacy='Lokaler Alt-Wert (RDP-Tcp)'; note='Die Benutzerrichtlinie hat Vorrang vor der globalen Richtlinie'; cur='Aktueller Wert'; seluser='Benutzer zum Konfigurieren wählen'; nousers='Keine lokalen Benutzer gefunden'; apply='Angewendet: {0} = {1}'; cleared='Gelöscht: {0}'; clear_global='Löschen (nicht konfiguriert)'; clear_legacy='Lokalen Alt-Wert löschen (RDP-Tcp)'; gclear='Globale Richtlinie gelöscht'; legcleared='Lokaler Alt-Wert gelöscht'; err_hive='Profil von {0} nicht zugänglich (nie angemeldet oder unzureichende Rechte)'; err_write='Schreibverifikation fehlgeschlagen: {0}'; apply_note='Gilt für neue Sitzungen; aktive Sitzungen erfordern eine erneute Anmeldung' }
    es = @{ global='Política global'; user='Política por usuario'; notcfg='No configurado'; eff='Efectivo'; legacy='Local heredado (RDP-Tcp)'; note='La política por usuario prevalece sobre la global'; cur='Valor actual'; seluser='Seleccionar un usuario para configurar'; nousers='No se encontraron usuarios locales'; apply='Aplicado: {0} = {1}'; cleared='Borrado: {0}'; clear_global='Borrar (no configurado)'; clear_legacy='Borrar valor local heredado (RDP-Tcp)'; gclear='Política global borrada'; legcleared='Valor local heredado borrado'; err_hive='No se puede acceder al perfil de {0} (nunca inició sesión o permisos insuficientes)'; err_write='Error de verificación de escritura: {0}'; apply_note='Aplica para nuevas sesiones; las sesiones activas requieren un nuevo inicio de sesión' }
    ru = @{ global='Глобальная политика'; user='Политика пользователя'; notcfg='Не настроено'; eff='Действующее значение'; legacy='Локальный устаревший (RDP-Tcp)'; note='Политика пользователя имеет приоритет над глобальной'; cur='Текущее значение'; seluser='Выберите пользователя для настройки'; nousers='Локальные пользователи не найдены'; apply='Применено: {0} = {1}'; cleared='Очищено: {0}'; clear_global='Очистить (не настроено)'; clear_legacy='Очистить локальный устаревший параметр (RDP-Tcp)'; gclear='Глобальная политика очищена'; legcleared='Локальный устаревший параметр очищен'; err_hive='Нет доступа к профилю {0} (нет входа в систему или недостаточно прав)'; err_write='Не удалось проверить запись: {0}'; apply_note='Действует для новых сессий; активным сессиям требуется повторный вход' }
}
