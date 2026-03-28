# TestFlight Deployment — Full Walkthrough

Your macOS is too old to build/deploy to your iPhone directly, so we use
GitHub Actions (free macOS runners) to build the app and upload it to TestFlight.
You then install the app from TestFlight on your iPhone.

**What you need:**
- Your Mac (any macOS version — only used for Keychain Access and Terminal)
- A web browser
- Your iPhone with the TestFlight app installed (free from App Store)
- Your Apple Developer Program account (the one you already have)

---

## PART 1: Register the Bundle ID

Before creating the app, Apple needs to know about your app's bundle identifier.

1. Open Safari and go to: **https://developer.apple.com/account**
2. Sign in with your Apple ID (the one tied to your Developer Program)
3. In the left sidebar, click **Identifiers**
4. Click the **+** button (blue circle with plus) in the top-left area
5. Select **App IDs** → click **Continue**
6. Select **App** (not App Clip) → click **Continue**
7. Fill in:
   - **Description**: `ScanView3D`
   - **Bundle ID**: Select **Explicit**
   - In the text field, type exactly: `com.michael.scanview3d`
8. Scroll down to **Capabilities**. You do NOT need to enable anything special for LiDAR — it's available by default. Just leave defaults.
9. Click **Continue** → then **Register**

You should now see `com.michael.scanview3d` in your Identifiers list.

---

## PART 2: Create the App in App Store Connect

1. Go to: **https://appstoreconnect.apple.com**
2. Sign in with the same Apple ID
3. Click **Apps** (or **My Apps**)
4. Click the **+** button in the top-left → select **New App**
5. A form appears. Fill it in exactly like this:

   | Field | Value |
   |-------|-------|
   | **Platforms** | Check **iOS** |
   | **Name** | `ScanView 3D` (this is what users see) |
   | **Primary Language** | English (U.S.) |
   | **Bundle ID** | Select `com.michael.scanview3d` from dropdown (you registered this in Part 1) |
   | **SKU** | `scanview3d` (internal identifier, users never see this) |
   | **User Access** | Full Access |

6. Click **Create**

The app page opens. You don't need to fill in anything else right now — TestFlight
doesn't require app screenshots, descriptions, or review information.

---

## PART 3: Create an App Store Connect API Key

This key lets GitHub Actions upload builds to your TestFlight account without
needing your Apple ID password.

1. Go to: **https://appstoreconnect.apple.com/access/integrations/api**
   - If you see a prompt to "Request Access" or "Enable", click it first.
2. Click the **+** button next to "Active" to generate a new key
3. Fill in:
   - **Name**: `GitHub Actions`
   - **Access**: Select **App Manager**
4. Click **Generate**
5. The key appears in the list. You'll see two values on this page — **write these down now:**
   - **Issuer ID** — shown at the top of the page (looks like: `12345678-abcd-1234-abcd-123456789012`)
   - **Key ID** — shown in the table row for your key (looks like: `ABC1234DEF`)
6. Click **Download API Key** — this downloads a file named `AuthKey_XXXXXXXX.p8`
   - **WARNING: You can only download this file ONCE. If you lose it, you must create a new key.**
   - Save it somewhere safe, like your Desktop

**What you now have from this step:**
- `Issuer ID` (written down)
- `Key ID` (written down)
- `AuthKey_XXXXXXXX.p8` file (on your Desktop or Downloads)

---

## PART 4: Create a Distribution Certificate

This is the code signing certificate that proves the app comes from your developer account.

### Step 4a: Generate a Certificate Signing Request (CSR)

1. On your Mac, open **Keychain Access** (search for it in Spotlight, or find it in `/Applications/Utilities/`)
2. In the menu bar at the top of the screen, click:
   **Keychain Access** → **Certificate Assistant** → **Request a Certificate from a Certificate Authority...**
3. A window appears. Fill in:
   - **User Email Address**: Your Apple ID email
   - **Common Name**: Your full name (e.g., `Michael Smith`)
   - **CA Email Address**: Leave blank
   - **Request is**: Select **Saved to disk**
4. Click **Continue**
5. Save the file to your Desktop. It will be named `CertificateSigningRequest.certSigningRequest`

### Step 4b: Create the Certificate on Apple's Site

1. Go to: **https://developer.apple.com/account/resources/certificates/list**
2. Click the **+** button
3. Under **Software**, select **Apple Distribution**
   - Do NOT select "iOS Distribution" (that's the legacy name) or "Apple Development" (that's for debug builds)
4. Click **Continue**
5. Click **Choose File** and select the `CertificateSigningRequest.certSigningRequest` file from your Desktop
6. Click **Continue**
7. Click **Download** — this saves a file named `distribution.cer` to your Downloads
8. **Double-click** the `distribution.cer` file — this installs it in Keychain Access

### Step 4c: Export as .p12

1. Open **Keychain Access** (if it's not already open)
2. In the left sidebar, click **login** under "Default Keychains"
3. Click the **My Certificates** category tab (or **Certificates** tab)
4. Find the certificate named **Apple Distribution: [Your Name]** (or your team name)
   - If you see multiple, look for the one with the most recent expiration date
5. Right-click (or Control-click) on it → select **Export "Apple Distribution: ..."**
6. In the save dialog:
   - **File Format**: Personal Information Exchange (.p12)
   - **Save As**: `Certificates.p12`
   - **Where**: Desktop
7. Click **Save**
8. It asks you to **set a password** for the .p12 file:
   - Enter a password (e.g., `MySecureP12Password!`)
   - **REMEMBER THIS PASSWORD** — you'll need it as a GitHub secret
   - Click **OK**
9. It may ask for your Mac login password — enter it to authorize the export

**What you now have from this step:**
- `Certificates.p12` file on your Desktop
- The password you set for it (written down)

---

## PART 5: Create a Provisioning Profile

This links your app's bundle ID to your distribution certificate, telling Apple
"this certificate is allowed to sign this app for the App Store / TestFlight."

1. Go to: **https://developer.apple.com/account/resources/profiles/list**
2. Click the **+** button
3. Under **Distribution**, select **App Store Connect**
4. Click **Continue**
5. In the **App ID** dropdown, select: `ScanView3D (com.michael.scanview3d)`
6. Click **Continue**
7. Select the **Apple Distribution** certificate you just created (check the box)
8. Click **Continue**
9. **Provisioning Profile Name**: type `ScanView3D AppStore`
10. Click **Generate**
11. Click **Download** — saves `ScanView3D_AppStore.mobileprovision` to your Downloads

**What you now have from this step:**
- `ScanView3D_AppStore.mobileprovision` file

---

## PART 6: Base64-Encode Your Files

GitHub Secrets only accept text, so you need to convert your binary files to
base64 text. Open **Terminal** on your Mac (Spotlight → type "Terminal") and run
these commands one at a time.

**Adjust the file paths below if you saved files somewhere other than Desktop/Downloads.**

```bash
# 1. Encode the API key (.p8 file)
# Replace XXXXXXXX with your actual key ID from Part 3
base64 -i ~/Desktop/AuthKey_XXXXXXXX.p8 | pbcopy
echo "API key copied to clipboard"
```
After running this, open a text file (TextEdit) and paste (Cmd+V). Label it `APP_STORE_CONNECT_KEY_CONTENT`. Save it.

```bash
# 2. Encode the distribution certificate (.p12 file)
base64 -i ~/Desktop/Certificates.p12 | pbcopy
echo "Certificate copied to clipboard"
```
Paste into your text file. Label it `APPLE_CERTIFICATE_BASE64`.

```bash
# 3. Encode the provisioning profile
base64 -i ~/Downloads/ScanView3D_AppStore.mobileprovision | pbcopy
echo "Profile copied to clipboard"
```
Paste into your text file. Label it `PROVISIONING_PROFILE_BASE64`.

You should now have a text file with three long base64 strings.

---

## PART 7: Add Secrets to GitHub

1. Open your browser and go to your GitHub repository:
   **https://github.com/Miobat/Claude-3D**
2. Click the **Settings** tab (gear icon, far right in the tab bar)
3. In the left sidebar, scroll down and click **Secrets and variables** → **Actions**
4. You'll add 8 secrets. For each one, click **New repository secret**, enter the Name and Value, then click **Add secret**:

| # | Secret Name | What to enter as the Value |
|---|-------------|---------------------------|
| 1 | `APP_STORE_CONNECT_KEY_ID` | The Key ID you wrote down in Part 3 (e.g., `ABC1234DEF`) |
| 2 | `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID you wrote down in Part 3 (e.g., `12345678-abcd-1234-abcd-123456789012`) |
| 3 | `APP_STORE_CONNECT_KEY_CONTENT` | The base64 text from step 1 in Part 6 (the long string) |
| 4 | `APPLE_CERTIFICATE_BASE64` | The base64 text from step 2 in Part 6 (the long string) |
| 5 | `APPLE_CERTIFICATE_PASSWORD` | The password you set in Part 4c step 8 (e.g., `MySecureP12Password!`) |
| 6 | `PROVISIONING_PROFILE_BASE64` | The base64 text from step 3 in Part 6 (the long string) |
| 7 | `PROVISIONING_PROFILE_NAME` | Type exactly: `ScanView3D AppStore` |
| 8 | `KEYCHAIN_PASSWORD` | Make up any random password (e.g., `ci-keychain-2024`). This is only used temporarily during the build. |

After adding all 8, you should see them listed on the Actions secrets page.

---

## PART 8: Trigger the Build

**Option A — Manual trigger (recommended for first time):**

1. Go to: **https://github.com/Miobat/Claude-3D/actions**
2. In the left sidebar, click **Build & Deploy to TestFlight**
3. Click the **Run workflow** dropdown button (right side)
4. Make sure the branch is `main` (or whichever has the workflow file)
5. Click the green **Run workflow** button
6. Click on the running workflow to watch the logs in real-time

**Option B — Automatic (after first successful build):**
Every time you push changes to files in `ScanView3D/` on `main`, it builds automatically.

### What to expect:

- The build takes about **10-20 minutes**
- You can watch the progress in the Actions tab
- If it fails, click into the failed step to see the error log
- If it succeeds, you'll see a green checkmark

---

## PART 9: Install on Your iPhone via TestFlight

1. On your iPhone, open the **App Store** and search for **TestFlight**
   - Install it if you don't have it (it's free, made by Apple)
2. Open **TestFlight**
3. If this is your first build, you'll receive an **email from Apple** (to your Apple ID email) within 15-30 minutes after the build uploads. The email subject will be something like "A new build is available for testing"
4. In TestFlight, you should see **ScanView 3D** listed
5. Tap on it → tap **Install**
6. The app installs on your home screen like any other app
7. Open it and start scanning!

### If you don't see the app in TestFlight:
- Go to **App Store Connect** → **My Apps** → **ScanView 3D** → **TestFlight** tab
- Check if the build is listed and what its status is
- If it says "Processing", wait 15-30 min
- If it says "Missing Compliance", click it and select "None of the algorithms mentioned above" (standard encryption exemption for apps that only use HTTPS)

---

## Summary of Files You Created

| File | Where | GitHub Secret |
|------|-------|---------------|
| `AuthKey_XXXXXXXX.p8` | Desktop | `APP_STORE_CONNECT_KEY_CONTENT` (base64) |
| `Certificates.p12` | Desktop | `APPLE_CERTIFICATE_BASE64` (base64) |
| `.p12 password` | Written down | `APPLE_CERTIFICATE_PASSWORD` |
| `ScanView3D_AppStore.mobileprovision` | Downloads | `PROVISIONING_PROFILE_BASE64` (base64) |
| Key ID | Written down | `APP_STORE_CONNECT_KEY_ID` |
| Issuer ID | Written down | `APP_STORE_CONNECT_ISSUER_ID` |

---

## Troubleshooting

### Build fails: "No signing certificate found"
- In Part 4b, make sure you selected **Apple Distribution** (not "Apple Development")
- Make sure the .p12 export included the private key (it should show a disclosure triangle with a key icon in Keychain Access)
- Re-export and re-encode the .p12 if needed

### Build fails: "No provisioning profile matching"
- The profile must be **App Store Connect** type (not Development or Ad Hoc)
- The bundle ID in the profile must be exactly `com.michael.scanview3d`
- The profile must reference the same certificate you exported

### Build fails: "Invalid API key"
- Double-check Key ID and Issuer ID — copy-paste them, don't retype
- The .p8 content must be the base64-encoded version, not the raw file contents
- Make sure you didn't accidentally add spaces or newlines when pasting

### Build succeeds but no TestFlight build
- Processing on Apple's side takes 15-30 minutes
- Check App Store Connect → TestFlight tab for the build status
- First-time builds may require you to answer an export compliance question

### "This app cannot be installed because its integrity could not be verified"
- This means the provisioning profile doesn't match the certificate. Recreate the profile in Part 5.
