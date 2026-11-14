$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\app")
flutter create --project-name kasher_app --platforms=windows,android .
flutter pub get
flutter analyze
flutter test
Write-Host "Generated Windows and Android scaffolds. Run: flutter run -d windows"
