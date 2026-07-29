import SwiftUI
import StoreKit

/// Single-tier lifetime paywall — JellyGo Pro.
struct PaywallView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRedemption = false

    private var bundle: Bundle { AppState.currentBundle }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    header
                        .padding(.top, 24)

                    featureList

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 200)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .background(Color(.systemBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                purchaseSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .background(
                        Rectangle()
                            .fill(.regularMaterial)
                            .ignoresSafeArea(edges: .bottom)
                    )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await store.restore()
                            if store.isPro { dismiss() }
                        }
                    } label: {
                        Text(String(localized: "Restore", bundle: bundle))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onChange(of: store.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 1.0, green: 0.78, blue: 0.32).opacity(0.25),
                                 Color(red: 0.95, green: 0.55, blue: 0.20).opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 120, height: 120)
                    .blur(radius: 8)

                Image(systemName: "crown.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(LinearGradient(
                        colors: [Color(red: 1.0, green: 0.82, blue: 0.40),
                                 Color(red: 0.92, green: 0.50, blue: 0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .shadow(color: .orange.opacity(0.35), radius: 14, y: 6)
            }

            VStack(spacing: 6) {
                Text(String(localized: "JellyGo Pro", bundle: bundle))
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text(String(localized: "Unlock everything. One payment. Forever.", bundle: bundle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(spacing: 12) {
            featureCard(
                icon: "arrow.down.circle.fill",
                tint: Color.blue,
                title: String(localized: "Offline Downloads", bundle: bundle),
                description: String(localized: "Download movies and shows to watch anywhere, anytime.", bundle: bundle)
            )
            featureCard(
                icon: "person.2.circle.fill",
                tint: Color.purple,
                title: String(localized: "Multiple Servers & Accounts", bundle: bundle),
                description: String(localized: "Switch between unlimited Jellyfin servers and user accounts.", bundle: bundle)
            )
            featureCard(
                icon: "tv.fill",
                tint: Color.pink,
                title: String(localized: "Live TV", bundle: bundle),
                description: String(localized: "Watch live channels from your Jellyfin server.", bundle: bundle)
            )
            featureCard(
                icon: "sparkles",
                tint: Color.orange,
                title: String(localized: "All Future Pro Features", bundle: bundle),
                description: String(localized: "One-time purchase. Lifetime updates.", bundle: bundle)
            )
        }
    }

    private func featureCard(icon: String, tint: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Purchase Section (sticky bottom)

    private var purchaseSection: some View {
        VStack(spacing: 10) {
            if let error = store.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await store.purchase() }
            } label: {
                HStack(spacing: 12) {
                    if store.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text(String(localized: "Get Lifetime Access", bundle: bundle))
                            .font(.headline)
                        Spacer(minLength: 0)
                        Text(store.displayPrice)
                            .font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(.tint, in: Capsule())
                .shadow(color: .accentColor.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading || store.product == nil)

            HStack(spacing: 16) {
                Button {
                    showRedemption = true
                } label: {
                    Label(String(localized: "Redeem Code", bundle: bundle), systemImage: "ticket.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
                .offerCodeRedemption(isPresented: $showRedemption) { result in
                    if case .success = result {
                        Task { await store.refreshEntitlement() }
                    }
                }

                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(String(localized: "Family Sharing", bundle: bundle))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Text(String(localized: "One-time purchase. No subscription. Family Sharing supported.", bundle: bundle))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }
}
