//
//  WebViewController.swift
//  xCreds
//
//  Created by Timothy Perfitt on 4/5/22.
//  Modified for ClassLink OIDC tenant support
//

import Foundation
import Cocoa
@preconcurrency import WebKit
import OIDCLite

@available(macOS, deprecated: 11)
class WebViewController: NSViewController, TokenManagerFeedbackDelegate, WKNavigationDelegate {

    struct WebViewControllerError: Error {
        var errorDescription: String
    }

    @IBOutlet weak var refreshTitleTextField: NSTextField?
    @IBOutlet weak var webView: WKWebView!
    @IBOutlet weak var cancelButton: NSButton!

    @available(macOS, deprecated: 11)
    var tokenManager = TokenManager()
    var password: String?
    var updateCredentialsFeedbackDelegate: UpdateCredentialsFeedbackProtocol?

    // MARK: - Lifecycle
    override func viewWillAppear() {
        super.viewWillAppear()
        if let refreshTitleTextField = self.refreshTitleTextField {
            refreshTitleTextField.isHidden = !DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldShowRefreshBanner.rawValue)

            if let refreshBannerText = DefaultsOverride.standardOverride.string(forKey: PrefKeys.refreshBannerText.rawValue) {
                self.refreshTitleTextField?.stringValue = refreshBannerText
            }
        }
    }

    func loadPage() {
        Task { @MainActor in
            TCSLogWithMark("Clearing cookies and preparing login")
            self.webView.cleanAllCookies()
            self.webView.navigationDelegate = self
            self.tokenManager.feedbackDelegate = self
            self.clearCookies()

            let licenseState = LicenseChecker().currentLicenseState()

            switch licenseState {
            case .valid(let sec):
                let daysRemaining = Int(sec/(24*60*60))
                TCSLogWithMark("Valid license. Days remaining: \(daysRemaining)")
            case .trial(_):
                break
            case .invalid, .trialExpired, .expired:
                if let bundle = Bundle.findBundleWithName(name: "XCreds"),
                   let loadPageURL = bundle.url(forResource: "errorpage", withExtension: "html") {
                    self.webView.load(URLRequest(url: loadPageURL))
                }
                return
            }

            NotificationCenter.default.addObserver(self, selector: #selector(self.connectivityStatusHandler(notification:)), name: NSNotification.Name.connectivityStatus, object: nil)
            NetworkMonitor.shared.startMonitoring()

            do {
                TCSLogWithMark("Getting OIDC Login URL")
                let url = try await self.getOidcLoginURL()
                TCSLogWithMark("Loading URL: \(url.absoluteString)")
                self.webView.load(URLRequest(url: url))
                NetworkMonitor.shared.stopMonitoring()
            } catch {
                TCSLogWithMark("Error loading page: \(error)")
                self.showErrorPage(error: error)
            }
        }
    }

    @objc func connectivityStatusHandler(notification: Notification) {
        TCSLogWithMark("Network monitor: handling connectivity status update")
        Task {
            try? await tokenManager.oidc().getEndpoints()
            TCSLogWithMark("Refresh webview login")
            loadPage()
        }
    }

    // MARK: - Token Manager Delegates
    func invalidCredentials() {}
    func authenticationSuccessful() {}

    func credentialsUpdated(_ credentials: Creds) {
        TCSLogWithMark("Credentials updated locally")
        var credWithPass = credentials
        credWithPass.password = self.password
        updateCredentialsFeedbackDelegate?.credentialsUpdated(credWithPass)
    }

    func tokenError(_ err: String) {
        TCSLogErrorWithMark("authFailure: \(err)")
        XCredsAudit().auditError(err)
        NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":err])
    }

    func showErrorMessageAndDeny(_ message:String){
        // Subclasses override this
    }

    // MARK: - Private Helpers
    private func getOidcLoginURL() async throws -> URL {
        if let url = try await tokenManager.oidc().createLoginURL() {
            return url
        }
        throw WebViewControllerError(errorDescription: "Error getting OIDC URL")
    }

    private func showErrorPage(error: Error) {
        let loadPageTitle = DefaultsOverride.standardOverride.string(forKey: PrefKeys.loadPageTitle.rawValue)?.stripped ?? "Login Error"
        var loadPageInfo = DefaultsOverride.standardOverride.string(forKey: PrefKeys.loadPageInfo.rawValue)?.stripped ?? "An error occurred."

        loadPageInfo = loadPageInfo + "<br><br>" + (error as? WebViewControllerError ?? WebViewControllerError(errorDescription: error.localizedDescription)).errorDescription

        let html = "<!DOCTYPE html><html><head><style>.center-screen { display: flex;flex-direction: column;justify-content: center;align-items: center;text-align: center;min-height: 100vh;font-family: sans-serif;}</style></head><body><div class=\"center-screen\"> <h1>\(loadPageTitle)</h1><p>\(loadPageInfo)</p></div></body></html>"

        self.webView.loadHTMLString(html, baseURL: nil)
    }

    private func clearCookies() {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                print("Removing Cookie")
            }
        }
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        // CLASSLINK REDIRECT INTERCEPTOR
        //
        // ClassLink's OIDC flow redirects back to the configured redirectURI after
        // authentication completes. The redirect URL contains the authorization code
        // as a query parameter. Without interception, the webview would try to load
        // the redirect target (typically your school's website), which isn't what we want.
        //
        // This catches the redirect, cancels the navigation, extracts the auth code,
        // and exchanges it for tokens via the standard OIDC token endpoint.
        if let url = navigationAction.request.url,
           let targetRedirectURI = DefaultsOverride.standardOverride.string(forKey: PrefKeys.redirectURI.rawValue) {

            if url.absoluteString.starts(with: targetRedirectURI) {
                if let queryItems = URLComponents(string: url.absoluteString)?.queryItems,
                   let code = queryItems.first(where: { $0.name == "code" })?.value {

                    TCSLogWithMark("Intercepted authorization code. Exchanging for tokens.")

                    decisionHandler(.cancel)

                    let processingHTML = """
                    <html><body style='font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;'>
                    <div style='text-align:center;'>
                        <h3>Signing in...</h3>
                        <p>Please wait while we finish setting up your session.</p>
                    </div>
                    </body></html>
                    """
                    webView.loadHTMLString(processingHTML, baseURL: nil)

                    Task {
                        do {
                            let tokenResponse = try await self.tokenManager.oidc().getToken(code: code)
                            TCSLogWithMark("Tokens received successfully.")

                            DispatchQueue.main.async {
                                self.tokenManager.tokenResponse(tokens: tokenResponse)
                            }
                        } catch {
                            TCSLogErrorWithMark("Error exchanging code for token: \(error.localizedDescription)")
                            let errHTML = "<html><body><h3>Login Failed</h3><p>\(error.localizedDescription)</p></body></html>"
                            webView.loadHTMLString(errHTML, baseURL: nil)
                        }
                    }
                    return
                }
            }
        }

        // PASSWORD SCRAPING
        // Captures password from form fields for local keychain sync
        let idpHostName = DefaultsOverride.standardOverride.value(forKey: PrefKeys.idpHostName.rawValue)
        var idpHostNames = DefaultsOverride.standardOverride.value(forKey: PrefKeys.idpHostNames.rawValue)

        if idpHostNames == nil && idpHostName != nil {
            idpHostNames = [idpHostName]
        }
        let passwordElementID: String? = DefaultsOverride.standardOverride.value(forKey: PrefKeys.passwordElementID.rawValue) as? String

        webView.evaluateJavaScript("result", completionHandler: { response, error in
            if error == nil {
                if let responseDict = response as? NSDictionary,
                   let ids = responseDict["ids"] as? Array<String>,
                   let passwords = responseDict["passwords"] as? Array<String> {

                    guard passwords.count > 0 else { return }

                    guard let host = navigationAction.request.url?.host else { return }

                    var foundHostname = false
                    if let idpHostNames = idpHostNames as? Array<String?>, idpHostNames.contains(host) {
                        foundHostname = true
                    } else if ["login.microsoftonline.com", "login.live.com", "accounts.google.com"].contains(host) || host.contains("okta.com") {
                        foundHostname = true
                    }

                    if foundHostname {
                        if passwords.count == 3, passwords[1] == passwords[2] {
                            self.password = passwords[2]
                        } else if passwords.count == 2, passwords[0] == passwords[1] {
                            self.password = passwords[1]
                        } else if let passwordElementID = passwordElementID {
                            if ids.count == 1, ids[0] == passwordElementID, passwords.count == 1 {
                                self.password = passwords[0]
                            }
                        } else if passwords.count == 1 {
                            self.password = passwords[0]
                        }
                    }
                }
            }
        })

        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {

        // CLASSLINK TENANT AUTO-NAVIGATION
        //
        // ClassLink's OIDC/OAuth2 flow always loads the generic "Find your login page"
        // at launchpad.classlink.com. ClassLink has confirmed this is intentional and
        // they won't change it (they suggested SAML instead, which XCreds doesn't use).
        //
        // When the classLinkTenant preference is set, this injects JavaScript that:
        // 1. Shows a white overlay so the user doesn't see the search page
        // 2. Types the tenant code into the search bar
        // 3. Clicks the matching result to navigate to the tenant login page
        //
        // Set classLinkTenant to your tenant code (the slug after launchpad.classlink.com/).
        // Optionally set classLinkTenantDisplayName for a friendlier loading message.
        if let tenant = DefaultsOverride.standardOverride.string(forKey: "classLinkTenant"),
           !tenant.isEmpty,
           let url = webView.url?.absoluteString {

            // Only allow safe characters in tenant code to prevent JS injection
            let safeTenant = tenant.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !safeTenant.isEmpty else {
                TCSLogErrorWithMark("classLinkTenant contains only invalid characters, skipping injection")
                return
            }

            let isClassLink = url.contains("launchpad.classlink.com")
            let isAlreadyOnTenant = url.contains(safeTenant)
            let isMFA = url.contains("twoformauth")
            let isProcessingAuth = url.contains("code=") || url.contains("state=")

            if isClassLink && !isAlreadyOnTenant && !isMFA && !isProcessingAuth {

                let rawDisplayName = DefaultsOverride.standardOverride.string(forKey: "classLinkTenantDisplayName") ?? safeTenant
                let safeDisplayName = rawDisplayName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " " }

                TCSLogWithMark("ClassLink tenant injection: navigating to \(safeTenant)")

                let js = """
                (function() {
                    var overlay = document.createElement('div');
                    overlay.id = 'xcreds-redirect-mask';
                    overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:#ffffff;z-index:2147483647;display:flex;align-items:center;justify-content:center;font-family:-apple-system,system-ui,sans-serif;font-size:18px;color:#555;';
                    overlay.innerHTML = '<div><span style="display:inline-block;width:20px;height:20px;border:3px solid rgba(0,0,0,.3);border-radius:50%;border-top-color:#000;animation:spin 1s ease-in-out infinite;margin-right:10px;vertical-align:middle;"></span>Loading \(safeDisplayName) login...</div><style>@keyframes spin { to { transform: rotate(360deg); } }</style>';
                    document.body.appendChild(overlay);

                    setTimeout(function() { if(overlay && overlay.parentNode) overlay.remove(); }, 5000);

                    function waitFor(selector, callback) {
                        var startTime = Date.now();
                        var interval = setInterval(function() {
                            var el = document.querySelector(selector);
                            if (el) {
                                clearInterval(interval);
                                callback(el);
                            }
                            if (Date.now() - startTime > 4000) clearInterval(interval);
                        }, 50);
                    }

                    waitFor('.search-bar-input', function(input) {
                        var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
                        setter.call(input, "\(safeTenant)");
                        input.dispatchEvent(new Event('input', { bubbles: true }));
                        input.dispatchEvent(new Event('change', { bubbles: true }));
                        input.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));

                        waitFor('.dropdown-list-item', function() {
                            var targetButton = document.querySelector('button[data-code="\(safeTenant)"]');
                            if (targetButton) {
                                targetButton.click();
                            } else {
                                var headers = document.querySelectorAll('.item-header');
                                for (var i = 0; i < headers.length; i++) {
                                    if (headers[i].textContent.toLowerCase().includes('\(safeTenant.lowercased())')) {
                                        headers[i].click();
                                        break;
                                    }
                                }
                            }
                        });
                    });
                })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        // Password listener injection for keychain sync
        TCSLogWithMark("Adding listener for password")
        if let bundle = Bundle.findBundleWithName(name: "XCreds"),
           let pathURL = bundle.url(forResource: "get_pw", withExtension: "js"),
           let javascript = try? String(contentsOf: pathURL, encoding: .utf8) {

            webView.evaluateJavaScript(javascript, completionHandler: { response, error in
                if error != nil {
                    if UserDefaults.standard.bool(forKey: "reloadPageOnError") == true {
                        TCSLogWithMark("Reloading page due to JS error")
                        self.loadPage()
                    }
                }
            })
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        TCSLogErrorWithMark(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        TCSLogWithMark("Redirect error (often safe to ignore): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        // Backup handler for OAuth redirect. The primary handling is in decidePolicyFor above.
        Task {
            guard let url = webView.url else { return }
            TCSLogWithMark("WebDel:: Did Receive Redirect for: \(url.absoluteString)")

            let redirectURI = try await tokenManager.oidc().redirectURI

            if url.absoluteString.starts(with: redirectURI) {
                if let queryItems = URLComponents(string: url.absoluteString)?.queryItems,
                   let code = queryItems.first(where: { $0.name == "code" })?.value {

                    TCSLogWithMark("Found code in didReceiveServerRedirect. Getting tokens.")
                    let tokenResponse = try await tokenManager.oidc().getToken(code: code)
                    tokenManager.tokenResponse(tokens: tokenResponse)
                }
            }
        }
    }
}

// MARK: - Utilities
extension String {
    func sanitized() -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>| ")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)

        return self.components(separatedBy: invalidCharacters).joined(separator: "")
    }

    mutating func sanitize() {
        self = self.sanitized()
    }
}

extension WKWebView {
    func cleanAllCookies() {
        HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
        print("All cookies deleted")

        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            records.forEach { record in
                WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record], completionHandler: {})
            }
        }
    }

    func refreshCookies() {
        self.configuration.processPool = WKProcessPool()
    }
}
