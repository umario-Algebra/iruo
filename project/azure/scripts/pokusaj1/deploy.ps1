# =========================================================================
#  Azure deployment script IROU
# =========================================================================

# Parametri (EDITIRAJ po potrebi)
$resourceGroup = "muvodic-irou"
$location = "westeurope"
$basePath = "C:\azure\iruo\project\azure\scripts"
$csvFile = "$basePath\osobe.csv"
$sshKeyPath = "$basePath\id_rsa.pub"

# =========================================================================
# 1. LOGIN TO AZURE
# =========================================================================
Write-Host "Prijava na Azure..." -ForegroundColor Cyan
Connect-AzAccount

# =========================================================================
# 2. CREATE RESOURCE GROUP
# =========================================================================
if (-not (Get-AzResourceGroup -Name $resourceGroup -ErrorAction SilentlyContinue)) {
    Write-Host "Kreiram Resource Group: $resourceGroup u $location" -ForegroundColor Cyan
    New-AzResourceGroup -Name $resourceGroup -Location $location | Out-Null
} else {
    Write-Host "Resource Group $resourceGroup već postoji." -ForegroundColor Yellow
}

# =========================================================================
# 3. DEPLOY VNET I SUBNETOVE
# =========================================================================
Write-Host "Deployam VNET i subnetove..." -ForegroundColor Cyan
$vnetTemplate = "$basePath\vnet.json"
$vnetParams = "$basePath\vnet.parameters.json"

New-AzResourceGroupDeployment -ResourceGroupName $resourceGroup `
    -TemplateFile $vnetTemplate `
    -TemplateParameterFile $vnetParams `
    -Verbose

# =========================================================================
# 4. PARSIRANJE CSV-A (ZA DALJNJE KORISTENJE)
# =========================================================================
Write-Host "Parsiram CSV s korisnicima..." -ForegroundColor Cyan
if (-not (Test-Path $csvFile)) {
    Write-Host "CSV datoteka $csvFile nije pronađena!" -ForegroundColor Red
    exit 1
}
$korisnici = Import-Csv -Delimiter ";" -Path $csvFile

Write-Host "Nađeno korisnika: $($korisnici.Count)"
foreach ($korisnik in $korisnici) {
    Write-Host "$($korisnik.ime) $($korisnik.prezime) [$($korisnik.rola)]"
}

# =========================================================================
# 5. LOADING SSH KLJUCA (ZA VM-OVE)
# =========================================================================
if (-not (Test-Path $sshKeyPath)) {
    Write-Host "SSH ključ $sshKeyPath nije pronađen!" -ForegroundColor Red
    exit 1
}
$sshKey = Get-Content $sshKeyPath

# =========================================================================
# OVDJE IDE DALJNI DEPLOY: VM-OVI, DISKOVI, NSG, LB, STORAGE...
# (u sljedećim koracima proširujemo skriptu!)
# =========================================================================

Write-Host "`nPrvi koraci deploya završeni! VNET je deployan, CSV je parsiran, SSH ključ učitan."
Write-Host "Sljedeće: deploy VM-ova, diskova, storagea, LB itd." -ForegroundColor Cyan
Write-Host "`n(Provjeri resurse u RG $resourceGroup preko Azure portala!)" -ForegroundColor Green
