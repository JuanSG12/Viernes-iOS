# Prepara el Viernes Companion: crea su certificado propio y guarda su huella. No necesita administrador.
# Uso:  pwsh -File setup.ps1            (usa %APPDATA%\ViernesCompanion)
param([string]$DataDir = (Join-Path $env:APPDATA 'ViernesCompanion'))
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force $DataDir | Out-Null
$passphrase = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24))

$cert = New-SelfSignedCertificate -DnsName @('localhost', $env:COMPUTERNAME) -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddYears(2) -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -FriendlyName 'Viernes Companion'
$pfx = Join-Path $DataDir 'companion.pfx'
# AES-256 y no el cifrado antiguo: Node con OpenSSL 3 rechaza los PFX con 3DES/RC2.
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password (ConvertTo-SecureString $passphrase -AsPlainText -Force) -CryptoAlgorithmOption AES256_SHA256 | Out-Null
$fingerprint = ($cert.GetCertHash('SHA256') | ForEach-Object { $_.ToString('X2') }) -join ':'
Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)"     # no hace falta en el almacén de Windows: el servicio usa solo el archivo

$configPath = Join-Path $DataDir 'config.json'
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ port = 8443; folders = @(); repos = @(); scripts = [pscustomobject]@{}; tokens = @() } }
$config | Add-Member -NotePropertyName tls -NotePropertyValue ([pscustomobject]@{ pfx = $pfx; passphrase = $passphrase }) -Force
$config | Add-Member -NotePropertyName fingerprint -NotePropertyValue $fingerprint -Force
$config | ConvertTo-Json -Depth 8 | Set-Content $configPath -Encoding UTF8

# Solo este usuario puede leer la carpeta (contiene el certificado y su clave).
icacls $DataDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null

Write-Host "Listo. Carpeta de datos: $DataDir"
Write-Host "Huella SHA-256 del certificado (el iPhone la fija al emparejarse):"
Write-Host "  $fingerprint"
Write-Host ""
Write-Host "Siguientes pasos:"
Write-Host "  1) Autoriza una carpeta de solo lectura:  node server.js allow-folder docs C:\ruta\a\tus\documentos"
Write-Host "  2) Abre el puerto SOLO para tu red local (PowerShell como administrador):"
Write-Host "       New-NetFirewallRule -DisplayName 'Viernes Companion' -Direction Inbound -Protocol TCP -LocalPort 8443 -RemoteAddress LocalSubnet -Action Allow"
Write-Host "     Nunca abras ese puerto en el router ni lo publiques en internet."
Write-Host "  3) Inicia el servicio y abre un emparejamiento:  node server.js start --pair"
