import Foundation
import WebKit

/// Sends a result back to the web app as a CustomEvent, same pattern as push notifications.
private func dispatchIAPEvent(_ eventName: String, payload: [String: Any]) {
    DispatchQueue.main.async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        DreamLanguage.webView.evaluateJavaScript(
            "this.dispatchEvent(new CustomEvent('\(eventName)', { detail: \(json) }))"
        )
    }
}

/// Handles JS message: window.webkit.messageHandlers['iap-purchase'].postMessage({ cycle: 'monthly' | 'yearly' })
/// Replies with a JS CustomEvent 'iap-purchase-result', detail: { ok: true, jws: "..." } or { ok: false, error: "..." }
@available(iOS 15.0, *)
func handleIAPPurchase(message: WKScriptMessage) {
    var cycle: String?

    if let dict = message.body as? [String: Any] {
        cycle = dict["cycle"] as? String
    } else if let str = message.body as? String,
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        cycle = dict["cycle"] as? String
    }

    guard let cycle = cycle else {
        dispatchIAPEvent("iap-purchase-result", payload: ["ok": false, "error": "missing cycle"])
        return
    }

    Task {
        do {
            let jws = try await StoreKitManager.shared.purchase(cycle: cycle)
            dispatchIAPEvent("iap-purchase-result", payload: ["ok": true, "jws": jws])
        } catch {
            dispatchIAPEvent("iap-purchase-result", payload: ["ok": false, "error": error.localizedDescription])
        }
    }
}

/// Handles JS message: window.webkit.messageHandlers['iap-restore'].postMessage({})
/// Replies with a JS CustomEvent 'iap-restore-result', detail: { ok: true, jws: ["...", ...] } or { ok: false, error: "..." }
@available(iOS 15.0, *)
func handleIAPRestore() {
    Task {
        do {
            let jwsList = try await StoreKitManager.shared.restore()
            dispatchIAPEvent("iap-restore-result", payload: ["ok": true, "jws": jwsList])
        } catch {
            dispatchIAPEvent("iap-restore-result", payload: ["ok": false, "error": error.localizedDescription])
        }
    }
}
