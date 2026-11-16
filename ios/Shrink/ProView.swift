import StoreKit
import SwiftUI

/// "Free up all the space": Shrink Pro. Shown before a batch that needs it, from Home, and from Settings.
/// Never after the work is done, never over a finished file.
struct ProView: View {
    /// A frozen store for CI screenshots; nil uses the real one.
    var preview: Store? = nil
    private var store: Store { preview ?? .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var choice = Store.lifetimeID
    @State private var showPrivacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Free up all the space")
                            .font(.largeTitle.bold())
                        Text("Shrink Pro removes the 5 GB limit on Free up space.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        benefit("Free up space with no limit")
                        benefit("Pay once and get every Pro feature added later")
                        benefit("Sending stays free for everyone, as many as you like")
                    }
                    if store.unavailable && !store.previewPrices {
                        Text("Pro can't be bought right now. Check your connection and try again later.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            plan(id: Store.lifetimeID, name: "Pay once", detail: "Yours forever",
                                 price: store.lifetime?.displayPrice ?? (store.previewPrices ? "$19.99" : "…"))
                            plan(id: Store.yearlyID, name: "Yearly", detail: "Cancel anytime in Settings",
                                 price: "\(store.yearly?.displayPrice ?? (store.previewPrices ? "$7.99" : "…")) a year")
                        }
                        .accessibilityElement(children: .contain)
                    }
                    Text("No weekly plan. No free trial that charges you later.")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    Button {
                        guard let product = selectedProduct else { return }
                        Task {
                            await store.buy(product)
                            if store.isPro { dismiss() }
                        }
                    } label: {
                        Text(buyTitle).font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selectedProduct == nil || store.purchasing)
                    HStack(spacing: 4) {
                        Button("Restore purchase") {
                            Task {
                                await store.restore()
                                if store.isPro { dismiss() }
                            }
                        }
                        .frame(minHeight: 44)
                        Text("·").foregroundStyle(.secondary)
                        // Apple's standard licence for apps without their own.
                        Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                            .frame(minHeight: 44)
                        Text("·").foregroundStyle(.secondary)
                        Button("Privacy") { showPrivacy = true }
                            .frame(minHeight: 44)
                    }
                    .font(.footnote)
                    .disabled(store.purchasing)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .sheet(isPresented: $showPrivacy) {
                NavigationStack { PrivacyView() }
            }
            .alert("Shrink Pro", isPresented: Binding(get: { store.message != nil },
                                                      set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.message ?? "")
            }
            .task { await store.load() }
        }
    }

    private var selectedProduct: Product? {
        choice == Store.lifetimeID ? store.lifetime : store.yearly
    }

    private var buyTitle: String {
        if let product = selectedProduct {
            return choice == Store.lifetimeID ? "Get Pro for \(product.displayPrice)"
                                              : "Get Pro for \(product.displayPrice) a year"
        }
        if store.previewPrices { return choice == Store.lifetimeID ? "Get Pro for $19.99" : "Get Pro for $7.99 a year" }
        return "Get Pro"
    }

    private func benefit(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        }
    }

    private func plan(id: String, name: String, detail: String, price: String) -> some View {
        let selected = choice == id
        return Button {
            choice = id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(price).font(.headline)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shrink's privacy policy, in the app (also what the App Store links to).
struct PrivacyView: View {
    /// Off when it's pushed inside Settings, which has its own Done.
    var showsDone = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Everything happens on your iPhone. Your videos and photos are never uploaded, and Shrink has no servers.")
                Text("Shrink doesn't collect, keep or share personal information. No accounts, no ads, no tracking.")
                Text("Photos access is used only to list your videos' sizes and to save the smaller copies you ask for.")
                Text("If you use Report a problem, your email includes the details shown in it: app version, iPhone model, iOS version and what went wrong. It's used only to answer you.")
                Text("Purchases are handled by Apple. Shrink never sees your payment details.")
            } footer: {
                Text("Last updated November 2026.")
            }
        }
        .navigationTitle("Privacy")
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
