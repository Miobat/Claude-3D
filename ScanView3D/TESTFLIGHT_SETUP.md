# TestFlight Deployment via GitHub Actions

Since your macOS is too old to build directly for your iPhone, this guide sets up
GitHub Actions to build the app and push it to TestFlight automatically.

## Prerequisites

- Apple Developer Program membership (paid, $99/year)
- GitHub repository with Actions enabled

## Step-by-Step Setup

### 1. Create the App in App Store Connect

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Click **My Apps** → **+** → **New App**
3. Fill in:
   - **Platform**: iOS
   - **Name**: ScanView 3D
   - **Bundle ID**: Register `com.michael.scanview3d` (or create a new one)
   - **SKU**: `scanview3d`
4. Save

### 2. Create an App Store Connect API Key

1. Go to [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
2. Click **Generate API Key**
3. Name: `GitHub Actions`
4. Access: **App Manager**
5. Download the `.p8` key file — **you can only download this once!**
6. Note the **Key ID** and **Issuer ID** shown on the page

### 3. Create a Distribution Certificate

On your Mac (even with old macOS, Keychain Access works):

1. Open **Keychain Access** → **Certificate Assistant** → **Request a Certificate from a Certificate Authority**
   - Email: your Apple ID email
   - Common Name: your name
   - Request is: **Saved to disk**
   - Save the `.certSigningRequest` file

2. Go to [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list)
3. Click **+** → **Apple Distribution** → Continue
4. Upload your `.certSigningRequest` file
5. Download the `.cer` file
6. Double-click to install in Keychain Access

7. In Keychain Access, find the certificate, right-click → **Export** → save as `.p12`
   - Set a strong password (you'll need this as a GitHub secret)

### 4. Create a Provisioning Profile

1. Go to [Apple Developer → Profiles](https://developer.apple.com/account/resources/profiles/list)
2. Click **+** → **App Store Connect** → Continue
3. Select your App ID (`com.michael.scanview3d`)
4. Select your Distribution Certificate
5. Name: `ScanView3D AppStore`
6. Download the `.mobileprovision` file

### 5. Add GitHub Secrets

Go to your GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add these secrets:

| Secret Name | Value |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | The Key ID from step 2 (e.g., `ABC123DEF4`) |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID from step 2 (e.g., `12345678-1234-1234-1234-123456789012`) |
| `APP_STORE_CONNECT_KEY_CONTENT` | Base64-encoded `.p8` key: run `base64 -i AuthKey_XXXX.p8` |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded `.p12` certificate: run `base64 -i Certificates.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `PROVISIONING_PROFILE_BASE64` | Base64-encoded profile: run `base64 -i ScanView3D_AppStore.mobileprovision` |
| `PROVISIONING_PROFILE_NAME` | The profile name: `ScanView3D AppStore` |
| `KEYCHAIN_PASSWORD` | Any random string (used for temporary CI keychain) |

### 6. Trigger the Build

**Option A — Automatic:** Push changes to the `ScanView3D/` directory on the `main` or `master` branch.

**Option B — Manual:** Go to GitHub → **Actions** → **Build & Deploy to TestFlight** → **Run workflow**

### 7. Install via TestFlight

1. After the build uploads (~10-15 min), you'll get an email from Apple
2. Open **TestFlight** on your iPhone
3. The build will appear under **ScanView 3D**
4. Tap **Install**

## Base64 Encoding Commands (run on your Mac)

```bash
# Encode the .p8 API key
base64 -i ~/Downloads/AuthKey_XXXXXXXX.p8 | pbcopy
# Paste into APP_STORE_CONNECT_KEY_CONTENT secret

# Encode the .p12 certificate
base64 -i ~/Downloads/Certificates.p12 | pbcopy
# Paste into APPLE_CERTIFICATE_BASE64 secret

# Encode the provisioning profile
base64 -i ~/Downloads/ScanView3D_AppStore.mobileprovision | pbcopy
# Paste into PROVISIONING_PROFILE_BASE64 secret
```

## Troubleshooting

### "No signing certificate found"
- Make sure you exported an **Apple Distribution** certificate (not Development)
- Verify the `.p12` was base64-encoded correctly

### "No provisioning profile"
- Ensure the profile is for **App Store** distribution (not Development or Ad Hoc)
- The bundle ID in the profile must match `com.michael.scanview3d`

### "Invalid API key"
- Double-check the Key ID and Issuer ID
- The `.p8` content must be base64-encoded

### Build succeeds but no TestFlight email
- Processing can take 15-30 minutes on Apple's side
- Check App Store Connect → TestFlight for processing status
