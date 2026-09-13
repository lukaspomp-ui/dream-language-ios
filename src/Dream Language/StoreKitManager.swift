import Foundation
import StoreKit

/// Product identifiers for Dream Language Premium.
/// Must match exactly the Product IDs created in App Store Connect.
enum IAPProduct: String {
    case monthly = "6802682642"
    case yearly = "6802682642Y"

    init?(cycle: String) {
        switch cycle {
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default: return nil
        }
    }
}

enum IAPError: LocalizedError {
    case invalidCycle
    case productNotFound
    case userCancelled
    case pending
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidCycle: return "Unknown subscription cycle"
        case .productNotFound: return "Product not found in App Store Connect"
        case .userCancelled: return "Purchase cancelled"
        case .pending: return "Purchase pending approval"
        case .verificationFailed: return "Could not verify purchase"
        }
    }
}

/// Handles StoreKit 2 purchases for Dream Language Premium.
/// Called from the JS bridge in ViewController (message names "iap-purchase" / "iap-restore").
@available(iOS 15.0, *)
final class StoreKitManager {

    static let shared = StoreKitManager()

    private var transactionListener: Task<Void, Never>?

    private init() {
        transactionListener = listenForTransactions()
    }

    deinit {
        transactionListener?.cancel()
    }

    /// Buys the subscription for the given cycle ("monthly" / "yearly").
    /// Returns the signed transaction (JWS) as a string, to be verified by our backend.
    func purchase(cycle: String) async throws -> String {
        guard let iapProduct = IAPProduct(cycle: cycle) else {
            throw IAPError.invalidCycle
        }

        let products = try await Product.products(for: [iapProduct.rawValue])
        guard let product = products.first else {
            throw IAPError.productNotFound
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            let jws = verification.jwsRepresentation
            await transaction.finish()
            return jws
        case .userCancelled:
            throw IAPError.userCancelled
        case .pending:
            throw IAPError.pending
        @unknown default:
            throw IAPError.verificationFailed
        }
    }

    /// Restores existing purchases. Returns JWS strings for all currently
    /// entitled subscription transactions found on this Apple ID.
    func restore() async throws -> [String] {
        try await AppStore.sync()
        var results: [String] = []
        for await entitlement in Transaction.currentEntitlements {
            if (try? checkVerified(entitlement)) != nil {
                results.append(entitlement.jwsRepresentation)
            }
        }
        return results
    }

    /// Listens for transaction updates that happen outside an explicit purchase
    /// call (renewals, refunds, Ask to Buy approvals, etc.) and finishes them.
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await update in Transaction.updates {
                if let transaction = try? self.checkVerified(update) {
                    await transaction.finish()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw IAPError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }
}
