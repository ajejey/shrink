import StoreKit
import SwiftUI

/// Shrink Pro. Shown before a batch that needs it, from Home, from Settings, before Send several at once
/// and from Sending options. Never after the work is done, never over a finished file.
struct ProView: View {
    /// What the person tapped, for the headline.
    var reason: ProReason = .freeUp
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
                        Text(headline)
                            .font(.largeTitle.bold())
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        benefit("Shrink videos and clean up photos with no limit")
                        benefit("Send several videos or photos at once")
                        benefit("Use the whole limit, pick HEVC or the picture size, keep every detail")
                        benefit("Pay once and get every Pro feature added later")
                        benefit("Sending one at a time stays free for everyone")
                    }
                    if store.unavailable && !store.previewPrices {
                        Text("Pro can't be bought right now. Check your connection and try again later.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            plan(id: Store.lifetimeID, name: "Pay once", detail: "Yours forever",
                                 price: store.lifetime?.displayPrice ?? (store.previewPrices ? "$39.99" : "…"))
                            plan(id: Store.yearlyID, name: "Yearly", detail: "Cancel anytime in Settings",
                                 price: "\(store.yearly?.displayPrice ?? (store.previewPrices ? "$19.99" : "…")) a year")
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
                    .disabled((selectedProduct == nil && !store.previewPrices) || store.purchasing)
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

    private var headline: String {
        switch reason {
        case .freeUp: return "Free up all the space"
        case .several: return "Send several at once"
        case .options: return "Sending options"
        }
    }

    private var subtitle: String {
        switch reason {
        case .freeUp:
            return "Shrink Pro removes the 5 GB limit on Free up space: shrinking videos and cleaning up photos."
        case .several:
            return "Shrink Pro makes a whole pick of videos and photos fit the same place in one go."
        case .options:
            return "Shrink Pro lets you choose how files are made: the whole limit, the format, the picture size and every detail."
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
        if store.previewPrices { return choice == Store.lifetimeID ? "Get Pro for $39.99" : "Get Pro for $19.99 a year" }
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

extension ProScreen {
    /// The app's Pro screen, for the screens it shares with the share sheet (trim, Sending options).
    static let app = ProScreen { reason in AnyView(ProView(reason: reason)) }
}

/// Shrink's privacy policy, in the app (also what the App Store links to).
struct PrivacyView: View {
    /// Off when it's pushed inside Settings, which has its own Done.
    var showsDone = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Everything happens on your iPhone. Your videos and photos are never uploaded.")
                Text("Shrink has no accounts, no ads and no tracking. It collects nothing unless you send a report.")
                Text("Photos access is used only on your iPhone: to list your videos' sizes, to sort your photos into piles like duplicates and screenshots, and to save the smaller copies and still photos you ask for.")
                Text("If you send a report from Report a problem, it includes what you wrote, your email if you add it, and the details listed on the form: app version, iPhone model, iOS version, the job and what went wrong, and after a crash, iOS's summary of it (what kind of crash and where in Shrink's code), if you choose to send it. Never your videos, photos or their names. It goes to Shrink's support inbox (through Google, which runs it) and is used only to fix problems and answer you.")
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
