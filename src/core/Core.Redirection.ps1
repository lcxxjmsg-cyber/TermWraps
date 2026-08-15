# Core.Redirection.ps1 - 重定向策略 fDisable* 八项管理（TermWrap 独有增量）
# 依据：重定向三层机制分析——策略层开关与 wrapper 机制无关，TermWrap 会读取并遵守

$script:REDIRECT_ITEMS = @(
    @{ Key='fDisableCam';               Name='redirect_cam' },
    @{ Key='fDisableAudioCapture';      Name='redirect_mic' },
    @{ Key='fDisableCdm';               Name='redirect_drive' },
    @{ Key='fDisableClip';              Name='redirect_clip' },
    @{ Key='fDisableCpm';               Name='redirect_printer' },
    @{ Key='fDisableSmartCard';         Name='redirect_smartcard' },
    @{ Key='fDisablePNPDeviceRedirection'; Name='redirect_pnp' },
    @{ Key='fDisableAudio';             Name='redirect_audio' }
)

function Get-RdpRedirectionState {
    $result = @()
    foreach ($item in $script:REDIRECT_ITEMS) {
        $v = Get-RegDword $REG_RDP_WS $item.Key
        $result += [PSCustomObject]@{
            Key = $item.Key
            Name = $item.Name
            Disabled = ($v -eq 1)
            Value = $v
        }
    }
    return $result
}

function Set-RdpRedirectionItem {
    param([string]$Key,[int]$Value)
    return (Set-RegDword $REG_RDP_WS $Key $Value)
}

function Reset-RdpRedirection {
    $ok = $true
    foreach ($item in $script:REDIRECT_ITEMS) {
        if (-not (Set-RdpRedirectionItem -Key $item.Key -Value 0)) { $ok = $false }
    }
    return $ok
}

function Show-RdpRedirectionMenu {
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  $(T 'menu_redirect_title')" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    $state = Get-RdpRedirectionState
    $i = 1
    foreach ($st in $state) {
        $flag = if ($st.Disabled) { '[OFF]' } else { '[ON]' }
        $color = if ($st.Disabled) { 'Red' } else { 'Green' }
        Write-Host "  $($i). $flag $(T $st.Name)" -ForegroundColor $color
        $i++
    }
    Write-Host "  9. $(T 'redirect_reset')" -ForegroundColor Yellow
    Write-Host "  0. $(T 'back_main')" -ForegroundColor Green
    Write-Host ""
    $c = Read-Host "> $(T 'sel_opt')"
    if ($c -match '^[1-8]$') {
        $item = $state[[int]$c - 1]
        $newVal = if ($item.Disabled) { 0 } else { 1 }
        if (Set-RdpRedirectionItem -Key $item.Key -Value $newVal) {
            Write-S "$(T $item.Name): $(if ($newVal -eq 1) { '[OFF]' } else { '[ON]' })"
        } else { Write-E "写入失败: $($item.Key)" }
    } elseif ($c -eq '9') {
        if (Reset-RdpRedirection) { Write-S "$(T 'redirect_reset') OK" } else { Write-E "恢复失败" }
    } elseif ($c -ne '0') { Write-E "$(T 'inv_opt')" }
    Write-Host ""; cmd /c pause 2>&1 | Out-Null
}
