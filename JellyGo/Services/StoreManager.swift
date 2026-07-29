import Foundation
import Combine
import StoreKit
import SwiftUI

/// Manages JellyGo Pro lifetime IAP via StoreKit 2.
/// Single non-consumable product. No subscriptions, no tiers.
@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    static let lifetimeProductID = "com.baykatre.JellyGo.pro.lifetime"

    @Published private(set) var product: Product?
    @Published private(set) var isPro: Bool = false
    @Published private(set) var isLoading = false
    @Published private(set) var purchaseError: String?

    private var transactionListener: Task<Void, Never>?

    private init() {
        // Restore persisted state immediately so UI doesn't flash
        isPro = UserDefaults.standard.bool(forKey: "jellygo.isPro")
        transactionListener = startTransactionListener()
        Task {
            await loadProduct()
            await refreshEntitlement()
        }
    }

    deinit { transactionListener?.cancel() }

    // MARK: - Product Loading

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.lifetimeProductID])
            self.product = products.first
        } catch {
            print("[StoreManager] Failed to load product: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product else {
            purchaseError = NSLocalizedString("Product not available. Try again later.", comment: "")
            return
        }
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if let transaction = try? checkVerified(verification) {
                    await transaction.finish()
                    await refreshEntitlement()
                }
            case .userCancelled:
                break
            case .pending:
                purchaseError = NSLocalizedString("Purchase pending approval.", comment: "")
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore

    func restore() async {
        isLoading = true
        defer { isLoading = false }
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    // MARK: - Entitlement

    func refreshEntitlement() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.productID == Self.lifetimeProductID,
               transaction.revocationDate == nil {
                entitled = true
                break
            }
        }
        #if DEBUG
        // In debug builds, always Pro regardless of real entitlement
        isPro = true
        UserDefaults.standard.set(true, forKey: "jellygo.isPro")
        AppState.shared?.isPro = true
        #else
        isPro = entitled
        UserDefaults.standard.set(entitled, forKey: "jellygo.isPro")
        AppState.shared?.isPro = entitled
        #endif
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }

    // MARK: - Transaction Listener

    private func startTransactionListener() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? await self.checkVerified(result) {
                    await transaction.finish()
                    await self.refreshEntitlement()
                }
            }
        }
    }

    // MARK: - Display Helpers

    var displayPrice: String {
        product?.displayPrice ?? "$9.99"
    }
}
