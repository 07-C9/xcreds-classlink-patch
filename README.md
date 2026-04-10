# XCreds ClassLink Tenant Patch

A modification to [XCreds](https://github.com/twocanoes/xcreds) that makes ClassLink work properly as an OIDC identity provider for macOS login.

> **Breaking change in XCreds 5.9:** The `getToken()` API added a required `basicAuth` parameter. The `WebViewController.swift` in this repo is based on **XCreds 5.9** (build 9123) and is **not compatible with XCreds 5.6**. If you need the 5.6 version, check the git history for the previous commit.

<img width="1919" height="1080" alt="xcreds" src="https://github.com/user-attachments/assets/0112d6e7-033b-4919-b74f-c502809e7d36" />

## The Problem

ClassLink's OIDC/OAuth2 implementation always redirects users to a generic "Find your login page" screen at `launchpad.classlink.com`, regardless of how you configure things. Users have to search for and select their district before they can log in.

I opened a case with ClassLink about this (Case #00606606). Their response:

> "The redirect to the generic ClassLink page is intended with the OIDC/OAuth2 workflow. The reason being is this will allow for universal functionality. Unfortunately we cannot manipulate the issuer url to redirect to [your] login page. If JAMF Connect supports a SAML integration, this can be specified in the ClassLink SAML settings."

Neither Jamf Connect nor XCreds use SAML for login window auth - they use OIDC. So this is a dead end on ClassLink's side. I submitted feature requests to both [ClassLink](https://help.classlink.com) and [Jamf](https://ideas.jamf.com/ideas/ID-I-391), but as of early 2026 neither has addressed it.

This can't be fixed with configuration in Jamf Connect or stock XCreds. It requires modifying the source code that handles the webview navigation during login.

## The Solution

This patch modifies one file in the XCreds source - `WebViewController.swift` - to add two things:

### 1. Redirect Interceptor

ClassLink redirects back to your configured `redirectURI` after authentication with the authorization code in the URL. Without this patch, the webview tries to load whatever that redirect target is (your school website, localhost, etc.). The interceptor catches this redirect, cancels the navigation, extracts the auth code, and exchanges it for tokens through the normal OIDC flow. The user sees a clean "Signing in..." message during the exchange.

### 2. Tenant Auto-Navigation

When ClassLink loads the generic search page, JavaScript is injected that:
- Shows a white overlay with a spinner ("Loading YourDistrict login...")
- Programmatically searches for your tenant code in ClassLink's search bar
- Clicks the matching result
- Your district's actual login page loads underneath

The user never sees the generic search page. They just see a brief loading spinner, then their district's ClassLink login screen.

## Configuration

### Which type of ClassLink URL does your district use?

ClassLink has two URL styles for district login pages. **Check which one your district uses before configuring** - it affects both the patch settings and standard XCreds settings.

| URL Style | Example | Status |
|-----------|---------|--------|
| **Launchpad** (most districts) | `launchpad.classlink.com/yourdistrict` | Tested in production (~500 Macs) |
| **Login** (districts with passkeys enabled) | `login.classlink.com/my/yourdistrict` | **Known not working** - see below |

To check: visit `launchpad.classlink.com/yourdistrict` in a browser. If it stays on `launchpad.classlink.com`, you have the Launchpad style. If it redirects to `login.classlink.com/my/yourdistrict`, you have the Login style.

### Login-style districts: known incompatibility

This patch does not currently work for districts whose ClassLink tenant has been migrated to the `login.classlink.com` URL style (typically triggered by enabling passkey login).

**Verified infrastructure facts:**

- `https://login.classlink.com/.well-known/openid-configuration` does not serve an OIDC discovery document. It returns the SPA HTML shell (`Content-Type: text/html`), not JSON.
- `https://launchpad.classlink.com/.well-known/openid-configuration` is the only OIDC discovery endpoint in ClassLink's infrastructure. Its `issuer`, `authorization_endpoint`, `token_endpoint`, and `jwks_uri` claims all point to `launchpad.classlink.com`.

**Field report:** a district whose ClassLink tenant had been migrated to `login.classlink.com` attempted this patch and reported authentication succeeding but token exchange failing afterward. No migrated districts have reported success.

If your district has been migrated to `login.classlink.com`, there is no known working configuration for this patch. Consider opening a ticket with ClassLink support asking about OIDC endpoint availability on `login.classlink.com`. If you find a workaround, please open an issue.

### Patch preference keys

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `classLinkTenant` | String | Yes | Your ClassLink tenant code. This is the slug in your district's login URL - the part after `launchpad.classlink.com/` or `login.classlink.com/my/`. For example, if your login page is `launchpad.classlink.com/mydistrict` or `login.classlink.com/my/mydistrict`, set this to `mydistrict`. |
| `classLinkTenantDisplayName` | String | No | Friendly name shown on the loading overlay. Defaults to the search term (or tenant code if no search term is set). Example: `My School District` |
| `classLinkSearchTerm` | String | No | **Use this when your tenant code doesn't work as a ClassLink search term.** Some districts can't be found by searching their tenant code on ClassLink's search page - only the district name works. Set this to whatever text successfully finds your district on the ClassLink search page. If your tenant code works as a search term, you don't need this key. |

**How to check if you need `classLinkSearchTerm`:** Go to `launchpad.classlink.com` and type your tenant code into the search bar. If your district shows up, you don't need it. If it doesn't, try your district name instead - if that works, set `classLinkSearchTerm` to whatever text found your district.

### Standard XCreds keys you'll also need

These are standard XCreds preferences, not specific to this patch:

| Key | Value |
|-----|-------|
| `discoveryURL` | `https://launchpad.classlink.com/.well-known/openid-configuration` |
| `clientID` | Your ClassLink OIDC Client ID (from ClassLink Developer portal) |
| `clientSecret` | Your ClassLink OIDC Client Secret |
| `redirectURI` | The redirect URI configured in your ClassLink app (this is what the interceptor catches) |
| `idpHostName` | **Depends on your URL style.** See below. |

**Important - `idpHostName` must match where your login form actually lives:**

- **Launchpad style** (`launchpad.classlink.com/yourdistrict`): set `idpHostName` to `launchpad.classlink.com`
- **Login style** (`login.classlink.com/my/yourdistrict`): :warning: **not supported** - see [Login-style districts: known incompatibility](#login-style-districts-known-incompatibility) above. Do not deploy.

XCreds uses `idpHostName` to identify which page has the password form for local password sync. If this doesn't match the domain where you actually type your password, the password will not be captured and local password sync will silently fail. Your login will still work, but the local account password won't update to match the cloud password.

### Example configuration profile

- **`example-classlink.mobileconfig`** - For Launchpad-style districts (`launchpad.classlink.com/yourdistrict`). Tested in production.

### A note about the redirect URI

This one is a little weird. ClassLink requires your redirect URI's domain to be a verified domain in their Developer portal. We couldn't get `localhost` or `127.0.0.1` to work reliably as a verified domain for the redirect, so we ended up using our school's homepage URL (`https://www.yourschool.org/`).

This sounds wrong but it's fine - the redirect interceptor in this patch catches the redirect **before** the browser actually makes a request to that URL. ClassLink appends the authorization code to the redirect URI (`https://www.yourschool.org/?code=abc123`), the interceptor sees it match, cancels the navigation, and pulls the code out. Your school's website never actually loads and never sees the auth code.

Just make sure the `redirectURI` in your XCreds config profile matches exactly what you have set in your ClassLink Developer app settings.

### ClassLink Developer Portal Setup

1. Create an OIDC application in the ClassLink Developer portal
2. Add your redirect URI domain as a verified domain (we used our school homepage - see note above)
3. Set the redirect URI to match what you'll put in the XCreds config profile
4. Note your Client ID and Client Secret

See `example-classlink.mobileconfig` in this repo for a complete configuration profile.

## How to Use

Replace `XCreds/WebViewController.swift` with the version from this repo and deploy with the preference keys above via your MDM. Compiling and signing are required but not covered here.

## Limitations

- **Fragile to ClassLink UI changes.** The JavaScript targets specific CSS selectors on ClassLink's login page (`.search-bar-input`, `.dropdown-list-item`, `button[data-code="..."]`). If ClassLink redesigns their page, the auto-navigation will break. There's a 5-second timeout that removes the overlay if the script fails, so it degrades to showing the generic search page (same as without the patch).

- **No automatic updates.** You're compiling XCreds yourself, so you need to manually check for new XCreds releases and re-apply this patch.

- **Based on XCreds v5.9 (build 9123).** Newer versions may have changes to WebViewController.swift that require merging. This version is not compatible with XCreds 5.6 due to the `getToken()` API change (added `basicAuth` parameter).

## Password Handling

XCreds captures the password from the ClassLink login form at each login and sets the local account password to match. There's no ongoing real-time password sync while the user is logged in - the local password updates the next time they log in. For shared labs and K-12 environments this is usually fine.

XCreds also has a `PasswordOverwriteSilent` preference key that can silently reset the keychain if the IdP password has changed since the last login - worth looking into if students forgetting their previous password is a headache for you.

## Credits

- [XCreds](https://github.com/twocanoes/xcreds) by Twocanoes Software (Timothy Perfitt)
- ClassLink integration by Brad White, Peninsula School District
