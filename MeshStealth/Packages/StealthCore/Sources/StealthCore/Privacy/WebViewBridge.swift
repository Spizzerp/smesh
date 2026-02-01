import Foundation
import WebKit
import JavaScriptCore

// MARK: - WebView Bridge for JavaScript SDK Execution

/// Bridge for executing JavaScript SDKs that require WASM support
/// Used by ShadowWire for Bulletproof proof generation
@MainActor
public final class WebViewBridge: NSObject {

    // MARK: - Properties

    private var webView: WKWebView?
    private var isInitialized = false
    private var pendingCallbacks: [String: CheckedContinuation<JSResult, Error>] = [:]
    private var pageLoadContinuation: CheckedContinuation<Void, Never>?

    /// The bundled JavaScript to execute
    private let bundledJS: String

    /// Name of the global object exposed by the SDK
    private let globalObjectName: String

    /// Timeout for JavaScript operations
    private let operationTimeout: TimeInterval

    // MARK: - Types

    /// Result from JavaScript execution
    /// Note: Using @unchecked Sendable because [String: Any] contains non-Sendable Any,
    /// but we control the data flow and ensure safe crossing of actor boundaries
    public struct JSResult: @unchecked Sendable {
        public let success: Bool
        public let data: [String: Any]?
        public let error: String?

        public init(success: Bool, data: [String: Any]? = nil, error: String? = nil) {
            self.success = success
            self.data = data
            self.error = error
        }
    }

    // MARK: - Initialization

    /// Initialize the WebView bridge
    /// - Parameters:
    ///   - bundledJS: The JavaScript SDK bundle to load
    ///   - globalObjectName: Name of the global object (e.g., "shadowWire", "privacyCash")
    ///   - operationTimeout: Timeout for operations in seconds
    public init(bundledJS: String, globalObjectName: String, operationTimeout: TimeInterval = 60) {
        self.bundledJS = bundledJS
        self.globalObjectName = globalObjectName
        self.operationTimeout = operationTimeout
        super.init()
    }

    // MARK: - Lifecycle

    /// Initialize the WebView and load the SDK
    public func initialize() async throws {
        guard !isInitialized else { return }

        // Configure WebView
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Add message handler for callbacks
        let contentController = config.userContentController
        contentController.add(self, name: "nativeCallback")

        // Create WebView (hidden, just for JS execution)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        // Load blank page then inject SDK
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body>
            <script>
            // Native callback helper
            window.sendToNative = function(callbackId, success, data, error) {
                window.webkit.messageHandlers.nativeCallback.postMessage({
                    callbackId: callbackId,
                    success: success,
                    data: data,
                    error: error
                });
            };

            // Promise wrapper for native calls
            window.callNativeAsync = function(method, params) {
                return new Promise((resolve, reject) => {
                    const callbackId = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    window._pendingCallbacks = window._pendingCallbacks || {};
                    window._pendingCallbacks[callbackId] = { resolve, reject };

                    // Execute method and handle result
                    try {
                        const result = method(params);
                        if (result && typeof result.then === 'function') {
                            result.then(data => {
                                window.sendToNative(callbackId, true, data, null);
                            }).catch(err => {
                                window.sendToNative(callbackId, false, null, err.message || String(err));
                            });
                        } else {
                            window.sendToNative(callbackId, true, result, null);
                        }
                    } catch (err) {
                        window.sendToNative(callbackId, false, null, err.message || String(err));
                    }
                });
            };

            console.log('[WebViewBridge] Native helpers initialized');
            </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)

        // Wait for page to actually load using continuation
        DebugLogger.log("[WebViewBridge] Waiting for page load...")
        await withCheckedContinuation { continuation in
            self.pageLoadContinuation = continuation
        }
        DebugLogger.log("[WebViewBridge] Page load confirmed, waiting for DOM ready...")

        // Additional wait for DOM to be fully ready
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        // Inject the SDK bundle
        try await injectSDK()

        isInitialized = true
        DebugLogger.log("[WebViewBridge] Initialized with \(globalObjectName)")
    }

    /// Inject the SDK JavaScript using script element injection
    /// This handles large bundles better than evaluateJavaScript
    private func injectSDK() async throws {
        guard let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        // For large bundles, use script element injection instead of evaluateJavaScript
        // This avoids hitting size limits on the evaluateJavaScript method
        let bundleSize = bundledJS.count
        DebugLogger.log("[WebViewBridge] Injecting SDK bundle (\(bundleSize) chars)")

        if bundleSize > 500_000 {
            // Large bundle - use chunked injection via script element
            DebugLogger.log("[WebViewBridge] Using chunked injection for large bundle")
            try await injectLargeBundle()
        } else {
            // Small bundle - direct evaluation is fine
            do {
                let result = try await webView.evaluateJavaScript(bundledJS)
                DebugLogger.log("[WebViewBridge] SDK injected, result: \(String(describing: result))")
            } catch {
                DebugLogger.log("[WebViewBridge] Direct injection failed: \(error)")
                // Fallback to chunked injection
                try await injectLargeBundle()
            }
        }
    }

    /// Inject a large bundle by encoding as base64 and decoding in JS
    private func injectLargeBundle() async throws {
        guard let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        // Encode the bundle as base64 to safely pass through
        guard let bundleData = bundledJS.data(using: .utf8) else {
            throw PrivacyProtocolError.sdkLoadFailed("Failed to encode bundle as UTF-8")
        }
        let base64Bundle = bundleData.base64EncodedString()

        // Split into chunks if needed (very large strings can still cause issues)
        let chunkSize = 500_000 // 500KB chunks
        var chunks: [String] = []
        var index = base64Bundle.startIndex

        while index < base64Bundle.endIndex {
            let endIndex = base64Bundle.index(index, offsetBy: chunkSize, limitedBy: base64Bundle.endIndex) ?? base64Bundle.endIndex
            chunks.append(String(base64Bundle[index..<endIndex]))
            index = endIndex
        }

        DebugLogger.log("[WebViewBridge] Injecting bundle in \(chunks.count) chunk(s)")

        // First, set up the accumulator
        _ = try? await webView.evaluateJavaScript("window._sdkChunks = [];")

        // Send each chunk
        for (i, chunk) in chunks.enumerated() {
            let addChunk = "window._sdkChunks.push('\(chunk)');"
            _ = try? await webView.evaluateJavaScript(addChunk)
            DebugLogger.log("[WebViewBridge] Sent chunk \(i + 1)/\(chunks.count)")
        }

        // Decode and execute
        let executeScript = """
        (function() {
            try {
                var base64 = window._sdkChunks.join('');
                var decoded = atob(base64);
                delete window._sdkChunks;

                var script = document.createElement('script');
                script.type = 'text/javascript';
                script.text = decoded;
                document.head.appendChild(script);
                console.log('[WebViewBridge] Large bundle injected successfully');
                return { success: true };
            } catch (e) {
                console.log('[WebViewBridge] Script injection error: ' + e.message);
                return { success: false, error: e.message };
            }
        })();
        """

        do {
            let result = try await webView.evaluateJavaScript(executeScript)
            DebugLogger.log("[WebViewBridge] Large bundle execution result: \(String(describing: result))")
        } catch {
            DebugLogger.log("[WebViewBridge] Large bundle execution failed: \(error)")
            throw PrivacyProtocolError.sdkLoadFailed("Failed to inject large bundle: \(error.localizedDescription)")
        }

        // Give it time to execute - bundle footer code needs time to run
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s (increased from 0.5s)

        // Verify and ensure the global object is set
        let verifyScript = """
        (function() {
            console.log('[WebViewBridge] Post-injection verification for \(globalObjectName)');
            console.log('[WebViewBridge] typeof window.\(globalObjectName):', typeof window.\(globalObjectName));

            // Check both bundle types
            var hasShadowWireBundle = typeof ShadowWireBundle !== 'undefined';
            var hasPrivacyCashBundle = typeof PrivacyCashBundle !== 'undefined';
            console.log('[WebViewBridge] typeof ShadowWireBundle:', hasShadowWireBundle ? 'object' : 'undefined');
            console.log('[WebViewBridge] typeof PrivacyCashBundle:', hasPrivacyCashBundle ? 'object' : 'undefined');

            // If window.shadowWire isn't set but ShadowWireBundle exists, set it now
            if (typeof window.\(globalObjectName) === 'undefined') {
                console.log('[WebViewBridge] window.\(globalObjectName) not set, attempting extraction...');

                // Try ShadowWireBundle
                if (hasShadowWireBundle) {
                    console.log('[WebViewBridge] Attempting to extract from ShadowWireBundle...');
                    var keys = Object.keys(ShadowWireBundle).slice(0, 10);
                    console.log('[WebViewBridge] ShadowWireBundle keys (first 10):', keys.join(', '));

                    var target = ShadowWireBundle.shadowWire ||
                                 ShadowWireBundle.default ||
                                 ShadowWireBundle;

                    if (target && typeof target.init === 'function') {
                        window.\(globalObjectName) = target;
                        console.log('[WebViewBridge] Set window.\(globalObjectName) from ShadowWireBundle');
                    } else {
                        console.log('[WebViewBridge] Direct extraction failed, searching nested...');
                        // Look deeper for init method
                        for (var key of Object.keys(ShadowWireBundle)) {
                            var candidate = ShadowWireBundle[key];
                            if (candidate && typeof candidate === 'object' && typeof candidate.init === 'function') {
                                window.\(globalObjectName) = candidate;
                                console.log('[WebViewBridge] Set window.\(globalObjectName) from ShadowWireBundle.' + key);
                                break;
                            }
                        }
                    }
                }

                // Try PrivacyCashBundle
                if (hasPrivacyCashBundle && typeof window.\(globalObjectName) === 'undefined') {
                    console.log('[WebViewBridge] Attempting to extract from PrivacyCashBundle...');
                    var keys = Object.keys(PrivacyCashBundle).slice(0, 10);
                    console.log('[WebViewBridge] PrivacyCashBundle keys (first 10):', keys.join(', '));

                    var target = PrivacyCashBundle.privacyCash ||
                                 PrivacyCashBundle.default ||
                                 PrivacyCashBundle;

                    if (target && typeof target.init === 'function') {
                        window.\(globalObjectName) = target;
                        console.log('[WebViewBridge] Set window.\(globalObjectName) from PrivacyCashBundle');
                    }
                }
            }

            var result = typeof window.\(globalObjectName) !== 'undefined';
            if (result && window.\(globalObjectName)) {
                var methods = Object.keys(window.\(globalObjectName)).filter(function(k) {
                    return typeof window.\(globalObjectName)[k] === 'function';
                });
                console.log('[WebViewBridge] Available methods on \(globalObjectName):', methods.join(', '));
            } else {
                console.log('[WebViewBridge] ERROR: window.\(globalObjectName) still not available!');
                // List all window properties that might be relevant
                var windowKeys = Object.keys(window).filter(function(k) {
                    return k.toLowerCase().indexOf('shadow') !== -1 ||
                           k.toLowerCase().indexOf('privacy') !== -1 ||
                           k.toLowerCase().indexOf('cash') !== -1;
                });
                console.log('[WebViewBridge] Relevant window keys:', windowKeys.join(', '));
            }
            return { available: result };
        })();
        """

        do {
            let verifyResult = try await webView.evaluateJavaScript(verifyScript)
            DebugLogger.log("[WebViewBridge] Verification result: \(String(describing: verifyResult))")

            // Parse verification result
            if let dict = verifyResult as? [String: Any], let available = dict["available"] as? Bool {
                if !available {
                    DebugLogger.log("[WebViewBridge] WARNING: Global object \(globalObjectName) not available after verification")
                }
            }
        } catch {
            DebugLogger.log("[WebViewBridge] Verification failed: \(error)")
        }
    }

    /// Shutdown and cleanup
    public func shutdown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nativeCallback")
        webView = nil
        isInitialized = false
        pendingCallbacks.removeAll()
    }

    // MARK: - JavaScript Execution

    /// Execute a JavaScript function on the SDK
    /// - Parameters:
    ///   - method: Method name on the global object (e.g., "deposit", "withdraw")
    ///   - params: Parameters as a dictionary (will be JSON encoded)
    /// - Returns: Result from the JavaScript execution
    public func execute(method: String, params: [String: Any]) async throws -> JSResult {
        guard isInitialized, let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        let callbackId = "cb_\(Date().timeIntervalSince1970)_\(UUID().uuidString.prefix(8))"

        // Convert params to JSON
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let paramsJSON = String(data: paramsData, encoding: .utf8) ?? "{}"

        // Build JavaScript to execute with better error handling
        let js = """
        (async function() {
            try {
                // Check if global object exists
                if (typeof window.\(globalObjectName) === 'undefined') {
                    console.log('[WebViewBridge] ERROR: window.\(globalObjectName) is undefined');
                    console.log('[WebViewBridge] Available globals:', Object.keys(window).filter(k => k.startsWith('shadow') || k.startsWith('Shadow')));
                    console.log('[WebViewBridge] typeof ShadowWireBundle:', typeof ShadowWireBundle);
                    if (typeof ShadowWireBundle !== 'undefined') {
                        console.log('[WebViewBridge] ShadowWireBundle keys:', Object.keys(ShadowWireBundle).slice(0, 10));
                    }
                    window.sendToNative('\(callbackId)', false, null, 'Global object window.\(globalObjectName) is undefined. Check SDK bundle export.');
                    return;
                }

                // Check if method exists
                if (typeof window.\(globalObjectName).\(method) !== 'function') {
                    console.log('[WebViewBridge] ERROR: window.\(globalObjectName).\(method) is not a function');
                    console.log('[WebViewBridge] Available methods:', Object.keys(window.\(globalObjectName)));
                    window.sendToNative('\(callbackId)', false, null, 'Method \(method) not found on window.\(globalObjectName)');
                    return;
                }

                const params = \(paramsJSON);
                const result = await window.\(globalObjectName).\(method)(params);
                window.sendToNative('\(callbackId)', true, result, null);
            } catch (err) {
                console.log('[WebViewBridge] Execution error:', err.message || String(err));
                window.sendToNative('\(callbackId)', false, null, err.message || String(err));
            }
        })();
        """

        // Execute with timeout
        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSResult, Error>) in
                Task { @MainActor in
                    self.pendingCallbacks[callbackId] = continuation

                    self.webView?.evaluateJavaScript(js) { _, error in
                        if let error = error {
                            if let continuation = self.pendingCallbacks.removeValue(forKey: callbackId) {
                                continuation.resume(throwing: PrivacyProtocolError.jsExecutionFailed(error.localizedDescription))
                            }
                        }
                        // Otherwise wait for callback
                    }
                }
            }
        }
    }

    /// Execute raw JavaScript
    /// - Parameter script: JavaScript to execute
    /// - Returns: Result from execution
    public func executeRaw(_ script: String) async throws -> Any? {
        guard isInitialized, let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        return try await webView.evaluateJavaScript(script)
    }

    // MARK: - Helpers

    /// Execute with a timeout
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PrivacyProtocolError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewBridge: WKScriptMessageHandler {
    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "nativeCallback",
              let body = message.body as? [String: Any],
              let callbackId = body["callbackId"] as? String else {
            return
        }

        let success = body["success"] as? Bool ?? false
        let data = body["data"] as? [String: Any]
        let error = body["error"] as? String

        let result = JSResult(success: success, data: data, error: error)

        Task { @MainActor in
            if let continuation = self.pendingCallbacks.removeValue(forKey: callbackId) {
                if success {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: PrivacyProtocolError.jsExecutionFailed(error ?? "Unknown error"))
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewBridge: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLogger.log("[WebViewBridge] Page loaded")
        Task { @MainActor in
            // Resume the page load continuation if waiting
            if let continuation = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                continuation.resume()
            }
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLogger.log("[WebViewBridge] Navigation failed: \(error)")
        Task { @MainActor in
            // Resume with error state (page still usable for some operations)
            if let continuation = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                continuation.resume()
            }
        }
    }
}

// MARK: - JSContext Bridge for Pure JavaScript SDKs

/// Lighter-weight bridge using JavaScriptCore for SDKs that don't need WASM
/// Used by Privacy Cash
public actor JSContextBridge {

    // MARK: - Properties

    private var context: JSContext?
    private var isInitialized = false

    /// The bundled JavaScript to execute
    private let bundledJS: String

    /// Name of the global object exposed by the SDK
    private let globalObjectName: String

    // MARK: - Initialization

    /// Initialize the JSContext bridge
    /// - Parameters:
    ///   - bundledJS: The JavaScript SDK bundle to load
    ///   - globalObjectName: Name of the global object (e.g., "privacyCash")
    public init(bundledJS: String, globalObjectName: String) {
        self.bundledJS = bundledJS
        self.globalObjectName = globalObjectName
    }

    // MARK: - Lifecycle

    /// Initialize the context and load the SDK
    public func initialize() async throws {
        guard !isInitialized else { return }

        guard let context = JSContext() else {
            throw PrivacyProtocolError.sdkLoadFailed("Failed to create JSContext")
        }

        // Set up error handling
        context.exceptionHandler = { _, exception in
            DebugLogger.log("[JSContextBridge] JS Exception: \(exception?.toString() ?? "unknown")")
        }

        // Add console.log support
        let consoleLog: @convention(block) (String) -> Void = { message in
            DebugLogger.log("[JSContextBridge] console.log: \(message)")
        }
        context.setObject(consoleLog, forKeyedSubscript: "consoleLog" as NSString)
        context.evaluateScript("var console = { log: consoleLog, error: consoleLog, warn: consoleLog, info: consoleLog };")

        // Add Web API polyfills that don't exist in JavaScriptCore
        context.evaluateScript(Self.webAPIPolyfills)

        DebugLogger.log("[JSContextBridge] Injecting SDK bundle (\(bundledJS.count) chars)...")

        // Inject the SDK bundle
        context.evaluateScript(bundledJS)

        // Check for JS exceptions after bundle execution
        if let exception = context.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            DebugLogger.log("[JSContextBridge] Bundle execution error: \(errorMsg)")
            context.exception = nil
        }

        // Try to find the global object - check multiple locations
        var globalObj = context.objectForKeyedSubscript(globalObjectName)

        // If not found directly, try to extract from bundle namespace
        if globalObj == nil || globalObj!.isUndefined {
            DebugLogger.log("[JSContextBridge] \(globalObjectName) not found directly, trying extraction...")

            // For PrivacyCash bundle
            let extractScript = """
            (function() {
                console.log('[JSContextBridge] Attempting global extraction...');

                // Check if the bundle module is available
                if (typeof PrivacyCashBundle !== 'undefined') {
                    console.log('[JSContextBridge] Found PrivacyCashBundle');
                    var target = PrivacyCashBundle.privacyCash || PrivacyCashBundle.default || PrivacyCashBundle;
                    if (target && typeof target.init === 'function') {
                        this.privacyCash = target;
                        console.log('[JSContextBridge] Extracted privacyCash from PrivacyCashBundle');
                        return true;
                    }
                }

                // Check globalThis
                if (typeof globalThis !== 'undefined' && globalThis.\(globalObjectName)) {
                    this.\(globalObjectName) = globalThis.\(globalObjectName);
                    console.log('[JSContextBridge] Copied from globalThis');
                    return true;
                }

                return false;
            })();
            """

            context.evaluateScript(extractScript)
            globalObj = context.objectForKeyedSubscript(globalObjectName)
        }

        // Final verification
        guard let obj = globalObj, !obj.isUndefined else {
            DebugLogger.log("[JSContextBridge] ERROR: Global object '\(globalObjectName)' not found after loading SDK")

            // Debug: List available globals
            #if DEBUG
            let listGlobals = "Object.keys(this).filter(function(k) { return typeof this[k] === 'object' || typeof this[k] === 'function'; }).join(', ')"
            if let globals = context.evaluateScript(listGlobals)?.toString() {
                DebugLogger.log("[JSContextBridge] Available globals: \(globals)")
            }
            #endif

            throw PrivacyProtocolError.sdkLoadFailed("Global object '\(globalObjectName)' not found after loading SDK")
        }

        // Log available methods
        #if DEBUG
        if let methods = obj.objectForKeyedSubscript("init"), !methods.isUndefined {
            DebugLogger.log("[JSContextBridge] \(globalObjectName).init is available")
        } else {
            DebugLogger.log("[JSContextBridge] WARNING: \(globalObjectName).init not found!")
        }
        #endif

        self.context = context
        isInitialized = true
        DebugLogger.log("[JSContextBridge] Initialized successfully with \(globalObjectName)")
    }

    /// Shutdown and cleanup
    public func shutdown() {
        context = nil
        isInitialized = false
    }

    // MARK: - JavaScript Execution

    /// Execute a function on the SDK
    /// - Parameters:
    ///   - method: Method name on the global object
    ///   - params: Parameters as a dictionary
    /// - Returns: Result from the JavaScript execution wrapped in JSResult
    public func execute(method: String, params: [String: Any]) async throws -> WebViewBridge.JSResult {
        guard isInitialized, let context = context else {
            throw PrivacyProtocolError.notInitialized
        }

        // Get the global object
        guard let globalObj = context.objectForKeyedSubscript(globalObjectName),
              !globalObj.isUndefined else {
            throw PrivacyProtocolError.notInitialized
        }

        // Get the method
        guard let methodFunc = globalObj.objectForKeyedSubscript(method),
              !methodFunc.isUndefined else {
            throw PrivacyProtocolError.jsExecutionFailed("Method '\(method)' not found")
        }

        // Convert params to JSValue
        let paramsValue = JSValue(object: params, in: context)

        // Call the method
        let result = methodFunc.call(withArguments: [paramsValue as Any])

        // Check for exception
        if let exception = context.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            context.exception = nil
            return WebViewBridge.JSResult(success: false, data: nil, error: errorMsg)
        }

        // Convert result to dictionary if possible
        let data = result?.toObject() as? [String: Any]
        return WebViewBridge.JSResult(success: true, data: data, error: nil)
    }

    /// Execute raw JavaScript
    /// - Parameter script: JavaScript to execute
    /// - Returns: Result from execution wrapped in JSResult
    public func executeRaw(_ script: String) async throws -> WebViewBridge.JSResult {
        guard isInitialized, let context = context else {
            throw PrivacyProtocolError.notInitialized
        }

        let result = context.evaluateScript(script)

        if let exception = context.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            context.exception = nil
            return WebViewBridge.JSResult(success: false, data: nil, error: errorMsg)
        }

        let data = result?.toObject() as? [String: Any]
        return WebViewBridge.JSResult(success: true, data: data, error: nil)
    }

    // MARK: - Web API Polyfills

    /// Polyfills for Web APIs that don't exist in JavaScriptCore
    /// Required for SDK bundles that use TextEncoder, TextDecoder, crypto, etc.
    private static let webAPIPolyfills = """
    // TextEncoder polyfill for JavaScriptCore
    if (typeof TextEncoder === 'undefined') {
        function TextEncoder() {}
        TextEncoder.prototype.encode = function(str) {
            var arr = [];
            for (var i = 0; i < str.length; i++) {
                var c = str.charCodeAt(i);
                if (c < 128) {
                    arr.push(c);
                } else if (c < 2048) {
                    arr.push((c >> 6) | 192);
                    arr.push((c & 63) | 128);
                } else if (c < 65536) {
                    arr.push((c >> 12) | 224);
                    arr.push(((c >> 6) & 63) | 128);
                    arr.push((c & 63) | 128);
                } else {
                    arr.push((c >> 18) | 240);
                    arr.push(((c >> 12) & 63) | 128);
                    arr.push(((c >> 6) & 63) | 128);
                    arr.push((c & 63) | 128);
                }
            }
            return new Uint8Array(arr);
        };
        this.TextEncoder = TextEncoder;
    }

    // TextDecoder polyfill for JavaScriptCore
    if (typeof TextDecoder === 'undefined') {
        function TextDecoder(encoding) {
            this.encoding = encoding || 'utf-8';
        }
        TextDecoder.prototype.decode = function(bytes) {
            if (!bytes) return '';
            var arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
            var result = '';
            var i = 0;
            while (i < arr.length) {
                var c = arr[i];
                if (c < 128) {
                    result += String.fromCharCode(c);
                    i++;
                } else if ((c & 224) === 192) {
                    result += String.fromCharCode(((c & 31) << 6) | (arr[i + 1] & 63));
                    i += 2;
                } else if ((c & 240) === 224) {
                    result += String.fromCharCode(((c & 15) << 12) | ((arr[i + 1] & 63) << 6) | (arr[i + 2] & 63));
                    i += 3;
                } else {
                    var cp = ((c & 7) << 18) | ((arr[i + 1] & 63) << 12) | ((arr[i + 2] & 63) << 6) | (arr[i + 3] & 63);
                    result += String.fromCodePoint(cp);
                    i += 4;
                }
            }
            return result;
        };
        this.TextDecoder = TextDecoder;
    }

    // atob/btoa polyfills for JavaScriptCore
    if (typeof atob === 'undefined') {
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
        this.atob = function(input) {
            var str = String(input).replace(/=+$/, '');
            var output = '';
            for (var bc = 0, bs, buffer, idx = 0; buffer = str.charAt(idx++);
                ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ?
                output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
                buffer = chars.indexOf(buffer);
            }
            return output;
        };
        this.btoa = function(input) {
            var str = String(input);
            var output = '';
            for (var block, charCode, idx = 0, map = chars;
                str.charAt(idx | 0) || (map = '=', idx % 1);
                output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
                charCode = str.charCodeAt(idx += 3/4);
                block = block << 8 | charCode;
            }
            return output;
        };
    }

    // crypto.getRandomValues polyfill (basic, not cryptographically secure)
    if (typeof crypto === 'undefined') {
        this.crypto = {
            getRandomValues: function(array) {
                for (var i = 0; i < array.length; i++) {
                    array[i] = Math.floor(Math.random() * 256);
                }
                return array;
            }
        };
    }

    // globalThis polyfill
    if (typeof globalThis === 'undefined') {
        this.globalThis = this;
    }

    // URL polyfill (basic)
    if (typeof URL === 'undefined') {
        function URL(url, base) {
            this.href = url;
            this.origin = '';
            this.protocol = '';
            this.host = '';
            this.pathname = url;
            this.search = '';
            this.hash = '';
        }
        URL.prototype.toString = function() { return this.href; };
        this.URL = URL;
    }

    // fetch polyfill stub (logs warning)
    if (typeof fetch === 'undefined') {
        this.fetch = function(url, options) {
            console.log('[Polyfill] fetch called but not available in JSContext: ' + url);
            return Promise.reject(new Error('fetch is not available in JavaScriptCore'));
        };
    }

    // setTimeout/setInterval stubs
    if (typeof setTimeout === 'undefined') {
        this.setTimeout = function(fn, delay) {
            // Immediate execution in JSContext (no real timer support)
            fn();
            return 0;
        };
        this.clearTimeout = function() {};
        this.setInterval = function(fn, delay) { return 0; };
        this.clearInterval = function() {};
    }

    // process polyfill (Node.js global)
    if (typeof process === 'undefined') {
        this.process = {
            env: {
                NODE_ENV: 'production'
            },
            browser: true,
            version: 'v18.0.0',
            versions: { node: '18.0.0' },
            platform: 'darwin',
            nextTick: function(fn) {
                if (typeof setTimeout !== 'undefined') {
                    setTimeout(fn, 0);
                } else {
                    fn();
                }
            },
            cwd: function() { return '/'; },
            exit: function() {},
            on: function() { return this; },
            once: function() { return this; },
            off: function() { return this; },
            emit: function() { return false; },
            listeners: function() { return []; },
            removeListener: function() { return this; },
            removeAllListeners: function() { return this; }
        };
    }

    // Buffer polyfill stub (many Node.js libs expect this)
    if (typeof Buffer === 'undefined') {
        this.Buffer = {
            from: function(data, encoding) {
                if (typeof data === 'string') {
                    var encoder = new TextEncoder();
                    return encoder.encode(data);
                }
                return new Uint8Array(data);
            },
            alloc: function(size) {
                return new Uint8Array(size);
            },
            isBuffer: function(obj) {
                return obj instanceof Uint8Array;
            },
            concat: function(list) {
                var totalLength = list.reduce(function(acc, arr) { return acc + arr.length; }, 0);
                var result = new Uint8Array(totalLength);
                var offset = 0;
                list.forEach(function(arr) {
                    result.set(arr, offset);
                    offset += arr.length;
                });
                return result;
            }
        };
    }

    console.log('[Polyfill] Web API polyfills loaded for JavaScriptCore');
    """
}
