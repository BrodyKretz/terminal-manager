import AppKit
import WebKit

/// --debug-script and --snapshot (debug builds only): drive the real page and capture the window
/// without touching the mouse or showing anything on screen.
@MainActor
enum DebugRunner {
    static func run(webView: WKWebView, scriptURL: URL?, snapshotURL: URL?, completion: @escaping @MainActor () -> Void) {
        runScript(webView: webView, scriptURL: scriptURL) {
            guard let snapshotURL else { return completion() }
            snapshot(webView: webView, to: snapshotURL) { _ in completion() }
        }
    }

    /// The file runs as the body of an async function, so it can await and return a value.
    private static func runScript(webView: WKWebView, scriptURL: URL?, then next: @escaping @MainActor () -> Void) {
        guard let scriptURL else { return next() }
        guard let source = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            emit("DEBUG_RESULT", ["error": "cannot read \(scriptURL.path)"])
            return next()
        }
        webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                emit("DEBUG_RESULT", value)
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                emit("DEBUG_RESULT", ["error": message ?? error.localizedDescription])
            }
            next()
        }
    }

    static func emit(_ tag: String, _ value: Any?) {
        print("\(tag) \(jsonLine(value))")
        fflush(stdout)
    }

    nonisolated static func jsonLine(_ value: Any?) -> String {
        let wrapped: [Any] = [value ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"unserializable\":true}"
        }
        return String(text.dropFirst().dropLast())
    }

    static func snapshot(webView: WKWebView, to url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                Log.error("snapshot failed: \(error?.localizedDescription ?? "no image")")
                return completion(false)
            }
            do {
                try png.write(to: url)
                Log.info("snapshot \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) written to \(url.path)")
                completion(true)
            } catch {
                Log.error("could not write the snapshot: \(error.localizedDescription)")
                completion(false)
            }
        }
    }
}
