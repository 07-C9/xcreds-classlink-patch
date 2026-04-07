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
class WebViewController: NSViewController, TokenManagerFeedbackDelegate {

    struct WebViewControllerError:Error {

        var errorDescription: String

    }
    func invalidCredentials() {
        
    }
    
    func authenticationSuccessful() {
        
    }

    func credentialsUpdated(_ credentials: Creds) {
        TCSLogWithMark()
        var credWithPass = credentials
        credWithPass.password = self.password
//        NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["credentials":credWithPass]
//                       )

        updateCredentialsFeedbackDelegate?.credentialsUpdated(credWithPass)
    }
  
    @IBOutlet weak var refreshTitleTextField: NSTextField?
    @IBOutlet weak var webView: WKWebView!
    @IBOutlet weak var cancelButton: NSButton!
    @available(macOS, deprecated: 11)
    var tokenManager=TokenManager()
    var password:String?
    var updateCredentialsFeedbackDelegate: UpdateCredentialsFeedbackProtocol?

    override func viewWillAppear() {
        if let refreshTitleTextField = self.refreshTitleTextField {
            refreshTitleTextField.isHidden = !DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldShowRefreshBanner.rawValue)


            if let refreshBannerText = DefaultsOverride.standardOverride.string(forKey: PrefKeys.refreshBannerText.rawValue) {
                self.refreshTitleTextField?.stringValue = refreshBannerText
            }

        }

    }
    func loadPage() {
        Task{ @MainActor in
            TCSLogWithMark("Clearing cookies")
            self.webView.cleanAllCookies()
            TCSLogWithMark()
            let licenseState = LicenseChecker().currentLicenseState()

            self.webView.navigationDelegate = self
            self.tokenManager.feedbackDelegate=self
            //            TokenManager.shared.oidc().delegate = self
            self.clearCookies()
            TCSLogWithMark()
            switch licenseState {

            case .valid(let sec):
                let daysRemaining = Int(sec/(24*60*60))
                TCSLogWithMark("valid license. Days remaining: \(daysRemaining) (\(sec) seconds)")
                if daysRemaining < 14 {
                }
                break;

            case .trial(_):
                break
            case .invalid,.trialExpired, .expired:
                let bundle = Bundle.findBundleWithName(name: "XCreds")

                if let bundle = bundle {
                    let loadPageURL = bundle.url(forResource: "errorpage", withExtension: "html")
                    if let loadPageURL = loadPageURL {
                        self.webView.load(URLRequest(url:loadPageURL))

                    }
                }
                return

            }

            NotificationCenter.default.addObserver(self, selector: #selector(self.connectivityStatusHandler(notification:)), name: NSNotification.Name.connectivityStatus, object: nil)

//            let discoveryURL = DefaultsOverride.standardOverride.string(forKey: PrefKeys.discoveryURL.rawValue)

            NetworkMonitor.shared.startMonitoring()
            TCSLogWithMark("Network monitor: adding connectivity status change observer")

            do {
//                guard let discoveryURL = discoveryURL else {
//                    TCSLogWithMark("discoveryURL not defined");
//
//                    throw WebViewControllerError(errorDescription: "The discovery URL not defined in settings. Verify that settings have been configured and scoped to the system (not user).")
//                }
                TCSLogWithMark("getOidcLoginURL");

                let url = try await self.getOidcLoginURL()
                TCSLogWithMark("URL: \(url)");

                self.webView.load(URLRequest(url: url))
                NetworkMonitor.shared.stopMonitoring()
            }
            catch {
                TCSLogWithMark("error: \(error)");

                let loadPageTitle = DefaultsOverride.standardOverride.string(forKey: PrefKeys.loadPageTitle.rawValue)?.stripped ?? "loadPageTitle"

                var loadPageInfo = DefaultsOverride.standardOverride.string(forKey: PrefKeys.loadPageInfo.rawValue)?.stripped ?? "loadPageInfo"


                loadPageInfo = loadPageInfo + "<br><br>" + (error as? WebViewControllerError ?? WebViewControllerError(errorDescription: error.localizedDescription)).errorDescription

                let html = "<!DOCTYPE html><html><head><style>.center-screen { display: flex;flex-direction: column;justify-content: center;align-items: center;text-align: center;min-height: 100vh;}</style></head><body><div class=\"center-screen\"> <h1>\(loadPageTitle)</h1><p>\(loadPageInfo)</p></div></body></html>"

                self.webView.loadHTMLString(html, baseURL: nil)

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



    private func getOidcLoginURL() async throws -> URL {
        if let url = try await tokenManager.oidc().createLoginURL() {
            return url
        }
        throw WebViewControllerError(errorDescription: "Error getting OIDC URL")
    }



    private func clearCookies() {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                 for: records,
                                 completionHandler: {
                print("Removing Cookie")
            })
        }

        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }
   
    func showErrorMessageAndDeny(_ message:String){
    }
    func tokenError(_ err: String) {
        TCSLogErrorWithMark("authFailure: \(err)")
        XCredsAudit().auditError(err)

        //TODO: need to post this?
        NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":err])

    }
}
@available(macOS, deprecated: 11)
extension WebViewController: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        // ClassLink redirect interceptor: catches the OIDC redirect back to our
        // redirectURI, cancels the navigation (so we don't load the school website),
        // extracts the auth code, and exchanges it for tokens.
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
                            let shouldUseBasicAuth = DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldUseBasicAuth.rawValue)
                            let tokenResponse = try await self.tokenManager.oidc().getToken(code: code, basicAuth: shouldUseBasicAuth)
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

        let idpHostName = DefaultsOverride.standardOverride.value(forKey: PrefKeys.idpHostName.rawValue)
        var idpHostNames = DefaultsOverride.standardOverride.value(forKey: PrefKeys.idpHostNames.rawValue)

        if idpHostNames == nil && idpHostName != nil {
            idpHostNames=[idpHostName]
        }
        let passwordElementID:String? = DefaultsOverride.standardOverride.value(forKey: PrefKeys.passwordElementID.rawValue) as? String

        TCSLogWithMark("inserting javascript to get password")
        webView.evaluateJavaScript("result", completionHandler: { response, error in
            if error != nil {
//                TCSLogWithMark(error?.localizedDescription ?? "unknown error")
                TCSLogWithMark("password not found")
            }
            else {
                if let responseDict = response as? NSDictionary, let ids = responseDict["ids"] as? Array<String>, let passwords = responseDict["passwords"] as? Array<String> {
                    
                    guard passwords.count > 0 else {
                        TCSLogWithMark("No passwords set")
                        return
                        
                    }

                    TCSLogWithMark("found password elements with ids:\(ids)")

                    guard let host = navigationAction.request.url?.host else {

                        return
                    }
                    var foundHostname = ""
                    if  let idpHostNames = idpHostNames as? Array<String?>,
                        idpHostNames.contains(host) {
                        foundHostname=host

                    }
                    else if ["login.microsoftonline.com", "login.live.com", "accounts.google.com"].contains(host) || host.contains("okta.com"){
                        foundHostname=host

                    }
                    else {
                        TCSLogWithMark("hostname (\(host)) not matched so not looking for password")
                        return
                    }

                    TCSLogWithMark("host matches custom idpHostName \(foundHostname)")


                    if passwords.count==3, passwords[1]==passwords[2] {
                        TCSLogWithMark("found 3 password fields. so it is a reset password situation")
                        TCSLogWithMark("========= password set===========")
                        self.password=passwords[2]
                    }
                    else if passwords.count==2, passwords[0]==passwords[1] {
                        TCSLogWithMark("found 2 password fields. so it is a reset password situation")
                        TCSLogWithMark("========= password set===========")
                        self.password=passwords[1]
                    }
                    else if let passwordElementID = passwordElementID{
                        TCSLogWithMark("the id is defined in prefs (\(passwordElementID)) so seeing if that field is on the page.")

                    // we have a mapped field defined in prefs so only check this.
                        if ids.count==1, ids[0]==passwordElementID, passwords.count==1 {
                            TCSLogWithMark("========= password set===========")
                            self.password=passwords[0]
                        }
                        else {

                            TCSLogWithMark("did not find a single password field on the page with the specified ID so not setting password")
                        }

                    }
                    //
                    else if passwords.count==1 {
                        TCSLogWithMark("found 1 password field on the specified page with the set idpHostName. setting password.")
                        TCSLogWithMark("========= password set===========")
                        self.password=passwords[0]

                    }
                    else {
                        TCSLogWithMark("No passwords found on page")
                    }
                }
                else {
                    
                    TCSLogWithMark("password not set")

                }
            }
        })
        decisionHandler(.allow)

    }

//    func setupAppearance() {
//        let screenRect = NSScreen.screens[0].frame
//
//        let screenWidth = screenRect.width
//        let screenHeight = screenRect.height
//
//
//        self.view.frame=NSMakeRect((screenWidth-CGFloat(loginWindowWidth))/2,(screenHeight-CGFloat(loginWindowHeight))/2, CGFloat(loginWindowWidth), CGFloat(loginWindowHeight))
//        TCSLogWithMark()
//
//    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {

        // ClassLink tenant auto-navigation: when classLinkTenant is set and the
        // webview loads the generic ClassLink search page, inject JS to search for
        // and click the tenant button automatically.
        if let tenant = DefaultsOverride.standardOverride.string(forKey: "classLinkTenant"),
           !tenant.isEmpty,
           let url = webView.url?.absoluteString {

            let safeTenant = tenant.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !safeTenant.isEmpty else {
                TCSLogErrorWithMark("classLinkTenant contains only invalid characters, skipping injection")
                // Fall through to password listener below
                return
            }

            let rawSearchTerm = DefaultsOverride.standardOverride.string(forKey: "classLinkSearchTerm")
            let safeSearchTerm: String
            if let rawSearchTerm = rawSearchTerm, !rawSearchTerm.isEmpty {
                let filtered = rawSearchTerm.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " " }
                safeSearchTerm = filtered.isEmpty ? safeTenant : filtered
            } else {
                safeSearchTerm = safeTenant
            }

            let isClassLink = url.contains("launchpad.classlink.com") || url.contains("login.classlink.com")
            let isAlreadyOnTenant = url.contains(safeTenant)
            let isMFA = url.contains("twoformauth")
            let isProcessingAuth = url.contains("code=") || url.contains("state=")

            if isClassLink && !isAlreadyOnTenant && !isMFA && !isProcessingAuth {

                let rawDisplayName = DefaultsOverride.standardOverride.string(forKey: "classLinkTenantDisplayName") ?? safeSearchTerm
                let safeDisplayName = rawDisplayName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " " }

                TCSLogWithMark("ClassLink tenant injection: navigating to \(safeTenant) (search: \(safeSearchTerm))")

                // Overlay + auto-click JS. All interpolated values are sanitized above
                // (alphanumeric + hyphens + underscores + spaces only).
                let js = """
                (function() {
                    var overlay = document.createElement('div');
                    overlay.id = 'xcreds-redirect-mask';
                    overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:#ffffff;z-index:2147483647;display:flex;align-items:center;justify-content:center;font-family:-apple-system,system-ui,sans-serif;font-size:18px;color:#555;';
                    overlay.textContent = '';
                    var spinner = document.createElement('span');
                    spinner.style.cssText = 'display:inline-block;width:20px;height:20px;border:3px solid rgba(0,0,0,.3);border-radius:50%;border-top-color:#000;animation:spin 1s ease-in-out infinite;margin-right:10px;vertical-align:middle;';
                    var style = document.createElement('style');
                    style.textContent = '@keyframes spin { to { transform: rotate(360deg); } }';
                    var wrapper = document.createElement('div');
                    wrapper.appendChild(spinner);
                    wrapper.appendChild(document.createTextNode('Loading \(safeDisplayName) login...'));
                    overlay.appendChild(wrapper);
                    overlay.appendChild(style);
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
                        setter.call(input, "\(safeSearchTerm)");
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
                                    if (headers[i].textContent.toLowerCase().includes('\(safeSearchTerm.lowercased())')) {
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

        // Password listener injection: attaches to keydown/keyup to capture
        // password fields for local keychain sync.
        TCSLogWithMark("adding listener for password")
        var pathURL:URL?
        let bundle = Bundle.findBundleWithName(name: "XCreds")

        if let bundle = bundle {
            TCSLogWithMark()
            pathURL = bundle.url(forResource: "get_pw", withExtension: "js")
            
        }

        guard let pathURL = pathURL else {
            TCSLogErrorWithMark("get_pw.js not found")
            return
        }

        let javascript = try? String(contentsOf: pathURL, encoding: .utf8)

        guard let javascript = javascript else {
            return
        }
        webView.evaluateJavaScript(javascript, completionHandler: { response, error in
            if (error != nil){
                
                TCSLogWithMark(error?.localizedDescription ?? "unknown listener error")
                if UserDefaults.standard.bool(forKey: "reloadPageOnError")==true {
                    TCSLogWithMark("reloading page")
                    self.loadPage()
                }
            }
            else {
                TCSLogWithMark("inserted javascript for password setup")
            }
        })

    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {


    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        TCSLogErrorWithMark(error.localizedDescription)


    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        TCSLogWithMark("Redirect error. if the error is \"Could not connect to the server.\", it is probably safe to ignore. If the error is \"unsupported URL\", please check your redirectURL in prefs matches the one defined in your OIDC app. Error: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        Task{
            guard let url = webView.url else {
                return
            }
            TCSLogWithMark("WebDel:: Did Receive Redirect for: \(url.absoluteString)")

            TCSLogWithMark("URL: \(url.absoluteString)")
            let redirectURI = try await tokenManager.oidc().redirectURI
            TCSLogWithMark("URL: \(url.absoluteString)")
            TCSLogWithMark("redirectURI: \(redirectURI)")

            if (url.absoluteString.starts(with: (redirectURI))) {
                TCSLogWithMark("got redirect URI match. separating URL")
                var code = ""
                let fullCommand = url.absoluteString
                let pathParts = fullCommand.components(separatedBy: "&")
                for part in pathParts {
                    if part.contains("code=") {
                        TCSLogWithMark("found code=. cleaning up.")

                        code = part.replacingOccurrences(of: redirectURI + "?" , with: "").replacingOccurrences(of: "code=", with: "")
                        TCSLogWithMark("getting tokens")

                        
                        do {
                            let shouldUseBasicAuth = DefaultsOverride.standardOverride.bool(forKey: PrefKeys.shouldUseBasicAuth.rawValue)
                            let tokenResponse = try await tokenManager.oidc().getToken(code: code, basicAuth: shouldUseBasicAuth)
                            TCSLogWithMark("got token. Token ID: \(tokenResponse.idToken ?? "" )")
                            tokenManager.tokenResponse(tokens: tokenResponse)

                        }
                        catch{
                            TCSLogWithMark("error: \(error)")
                        }

                        return
                    }
                }
            }
        }

    }

    private func queryToDict(query: String) -> [String:String]? {
        let components = query.components(separatedBy: "&")
        var dictionary = [String:String]()

        for pairs in components {
            let pair = pairs.components(separatedBy: "=")
            if pair.count == 2 {
                dictionary[pair[0]] = pair[1]
            }
        }

        if dictionary.count == 0 {
            return nil
        }

        return dictionary
    }


}

//TODO: Integrate?
//extension WebViewController: OIDCLiteDelegate {
//
////    func authFailure(message: String) {
////        TCSLogErrorWithMark("authFailure: \(message)")
////        NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:[:])
////
////    }
//
//    
//}
extension String {
    func sanitized() -> String {
        // see for ressoning on charachrer sets https://superuser.com/a/358861
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>| ")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)

        return self
            .components(separatedBy: invalidCharacters)
            .joined(separator: "")
    }

    mutating func sanitize() -> Void {
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
                print("Cookie ::: \(record) deleted")
            }
        }
    }

    func refreshCookies() {
        self.configuration.processPool = WKProcessPool()
    }
}
