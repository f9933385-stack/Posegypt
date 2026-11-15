$ErrorActionPreference = "Stop"
Push-Location (Join-Path $PSScriptRoot "..\server")
dart pub get
dart analyze
dart test
Pop-Location
Push-Location (Join-Path $PSScriptRoot "..\app")
flutter pub get
flutter analyze
flutter test
Pop-Location
