# Project Notes

## Developer Environment
- User's macOS is too old to build/deploy directly to their iPhone via Xcode
- Must use CI/CD (GitHub Actions + Xcode Cloud) to build the iOS app
- App is distributed via TestFlight through their Apple Developer Program account
- User has an Apple Developer Program membership (paid account)

## Project: ScanView3D
- Native iOS LiDAR scanning app located in `ScanView3D/`
- Requires iPhone 12 Pro or newer (LiDAR hardware)
- iOS 17.0+ deployment target
