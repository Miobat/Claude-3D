# Project Notes

## Developer Environment
- User's macOS is too old to build/deploy directly to their iPhone via Xcode
- Must use CI/CD (GitHub Actions + Xcode Cloud) to build the iOS app
- App is distributed via TestFlight through their Apple Developer Program account
- User has an Apple Developer Program membership (paid account)

## Apple Developer Account
- Account holder: Michael Tragethon
- Team ID: 2K36RTR5 (visible in top-right of developer portal)
- App Store Connect API Key ID: `V3M65TDS5B`
- App Store Connect Issuer ID: `13bfcc6f-f787-483d-bace-316f4cc84519`
- API Key Name: "GitHub Actions" (App Manager access)
- App name in App Store Connect: "Lidar ScanView"
- Bundle ID: `com.michael.scanview3d`

### GitHub Secrets mapping:
- `APP_STORE_CONNECT_KEY_ID` → `V3M65TDS5B`
- `APP_STORE_CONNECT_ISSUER_ID` → `13bfcc6f-f787-483d-bace-316f4cc84519`

## Project: ScanView3D
- Native iOS LiDAR scanning app located in `ScanView3D/`
- Requires iPhone 12 Pro or newer (LiDAR hardware)
- iOS 17.0+ deployment target
