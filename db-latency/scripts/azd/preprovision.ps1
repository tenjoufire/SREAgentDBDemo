$ErrorActionPreference = 'Stop'

function Get-EnvValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $item = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    return $item?.Value
}

function Set-AzdEnvIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if (-not (Get-EnvValue -Name $Name)) {
        azd env set $Name "$Value" | Out-Null
        Write-Host "$Name を設定しました。"
    }
}

function New-StrongPassword {
    param([int]$Length = 24)

    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $digits = '23456789'
    $special = '!@#%*_-'
    $all = "$lower$upper$digits$special"

    $passwordChars = [System.Collections.Generic.List[char]]::new()
    $passwordChars.Add($lower[(Get-Random -Minimum 0 -Maximum $lower.Length)])
    $passwordChars.Add($upper[(Get-Random -Minimum 0 -Maximum $upper.Length)])
    $passwordChars.Add($digits[(Get-Random -Minimum 0 -Maximum $digits.Length)])
    $passwordChars.Add($special[(Get-Random -Minimum 0 -Maximum $special.Length)])

    while ($passwordChars.Count -lt $Length) {
        $passwordChars.Add($all[(Get-Random -Minimum 0 -Maximum $all.Length)])
    }

    return -join ($passwordChars | Sort-Object { Get-Random })
}

if (-not (Get-EnvValue -Name 'ALERT_EMAIL')) {
    $signedInUser = az account show --query user.name -o tsv 2>$null
    if ($signedInUser -and $signedInUser.Contains('@')) {
        azd env set ALERT_EMAIL "$signedInUser" | Out-Null
        Write-Host "ALERT_EMAIL を $signedInUser に設定しました。"
    }
    else {
        throw 'ALERT_EMAIL が未設定です。azd env set ALERT_EMAIL you@example.com を実行してから再試行してください。'
    }
}

$signedInPrincipal = az ad signed-in-user show --query '{login:userPrincipalName,objectId:id}' -o json 2>$null | ConvertFrom-Json
if (-not $signedInPrincipal) {
    throw '現在のサインイン ユーザー情報を取得できませんでした。ユーザー アカウントで az login してから再試行してください。'
}

Set-AzdEnvIfMissing -Name 'SQL_AAD_ADMIN_LOGIN' -Value $signedInPrincipal.login
Set-AzdEnvIfMissing -Name 'SQL_AAD_ADMIN_OBJECT_ID' -Value $signedInPrincipal.objectId

if (-not (Get-EnvValue -Name 'SQL_AAD_ADMIN_TENANT_ID')) {
    $tenantId = az account show --query tenantId -o tsv
    azd env set SQL_AAD_ADMIN_TENANT_ID "$tenantId" | Out-Null
    Write-Host 'SQL_AAD_ADMIN_TENANT_ID を設定しました。'
}

if (-not (Get-EnvValue -Name 'SQL_ADMIN_PASSWORD')) {
    $generatedPassword = New-StrongPassword
    azd env set SQL_ADMIN_PASSWORD "$generatedPassword" | Out-Null
    Write-Host 'SQL_ADMIN_PASSWORD を自動生成しました。'
}