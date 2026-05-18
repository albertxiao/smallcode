Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Reinstalling smallcode from local fork..."
npm install
npm install -g .
Write-Host "Done. Run: smallcode --help"
