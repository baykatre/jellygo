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

    #if DEBUG
    /// Scheme launch argument `-jellygo.debugShowPaywall YES` forces Debug builds
    /// to honour the real entitlement, so the paywall can be tested without
    /// switching the scheme to Release.
    static let debugShowPaywall = UserDefaults.standard.bool(forKey: "jellygo.debugShowPaywall")
    #endif

    @Published private(set) var product: Product?
    @Published private(set) var isPro: Bool = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var purchaseError: String?
    /// True once a load attempt has finished without producing a product.
    /// Drives the paywall's retry affordance so the buy button is never permanently dead.
    @Published private(set) var productLoadFailed = false

    private var transactionListener: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private init() {
        // Restore persisted state immediately so UI doesn't flash
        isPro = UserDefaults.standard.bool(forKey: "jellygo.isPro")
        transactionListener = startTransactionListener()
        // Independent tasks: entitlement must not wait on the product-load retry
        // chain, or a stale persisted flag stays on screen for seconds.
        Task { await refreshEntitlement() }
        Task { await loadProductIfNeeded() }
    }

    deinit {
        transactionListener?.cancel()
        loadTask?.cancel()
    }

    // MARK: - Product Loading

    /// Loads the product if we don't already have it. Safe to call on every paywall
    /// presentation — concurrent callers join the in-flight attempt instead of
    /// firing duplicate StoreKit queries.
    func loadProductIfNeeded() async {
        if product != nil { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Forces a fresh attempt even if one already failed. Backs the paywall's Retry button.
    func retryLoadProduct() async {
        loadTask?.cancel()
        loadTask = nil
        await loadProductIfNeeded()
    }

    private func performLoad() async {
        isLoadingProduct = true
        defer { isLoadingProduct = false }

        #if DEBUG
        // Diagnostic: a nil storefront means StoreKit has no App Store connection
        // at all, which looks identical to "product not found" from products(for:).
        if let sf = await Storefront.current {
            print("[StoreManager] Storefront: \(sf.countryCode) id=\(sf.id)")
        } else {
            print("[StoreManager] Storefront: nil — no App Store storefront on this device")
        }
        #endif

        // StoreKit can return an empty result during launch while the App Store
        // account/network is still settling, so a single attempt is not enough.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return }
            do {
                let products = try await Product.products(for: [Self.lifetimeProductID])
                if let found = products.first {
                    product = found
                    productLoadFailed = false
                    purchaseError = nil
                    return
                }
                // Not an error from StoreKit's perspective: the ID simply came back
                // unknown to the App Store. Retrying covers the transient case.
                print("[StoreManager] Attempt \(attempt)/\(maxAttempts): no product returned for \(Self.lifetimeProductID)")
            } catch {
                print("[StoreManager] Attempt \(attempt)/\(maxAttempts) failed: \(error)")
            }

            if attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(Double(attempt)))
            }
        }

        productLoadFailed = true
    }

    // MARK: - Purchase

    func purchase() async {
        // Self-heal: if the launch-time load came back empty, try again on tap
        // rather than dead-ending the user.
        if product == nil {
            await retryLoadProduct()
        }
        guard let product else {
            purchaseError = NSLocalizedString("Couldn't reach the App Store. Check your connection and try again.", comment: "")
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
        // Debug builds are Pro by default so the paywall doesn't block development.
        // Launch with `-jellygo.debugShowPaywall YES` to exercise the real paywall.
        // Deliberately not persisted: a Release build installed over a Debug one
        // must not inherit a fake Pro flag from UserDefaults.
        isPro = Self.debugShowPaywall ? entitled : true
        AppState.shared?.isPro = isPro
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

    /// Real price from StoreKit, or nil when the product hasn't loaded.
    /// Never fall back to a hardcoded price — showing a price the user can't
    /// actually be charged is exactly what App Review flags.
    var displayPrice: String? {
        product?.displayPrice
    }
}
