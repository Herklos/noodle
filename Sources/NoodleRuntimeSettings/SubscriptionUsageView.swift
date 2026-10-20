import SwiftUI
import NoodleCore

/// How much of a signed-in account's plan limits is used and when each resets,
/// as its harness last reported them, or Not available when it reported nothing.
struct SubscriptionUsageView: View {
    let usage: SubscriptionUsage?

    var body: some View {
        // Only the countdown moves on its own; new readings come from the store.
        TimelineView(.everyMinute) { context in
            let windows = usage?.current(at: context.date) ?? []
            if windows.isEmpty {
                Text("Plan limits: \(SubscriptionUsageFormat.notAvailable)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("The harness has not reported this account’s plan limits.")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(windows) { window in
                        GridRow {
                            Text(SubscriptionUsageFormat.title(window))
                            // No bar for an unreported share, which an empty bar would show as none used.
                            Group {
                                if let fraction = SubscriptionUsageFormat.fraction(window) {
                                    ProgressView(value: fraction)
                                } else {
                                    Color.clear.frame(height: 1)
                                }
                            }
                            .frame(width: 100)
                            .accessibilityHidden(true)
                            Text(SubscriptionUsageFormat.detail(window, now: context.date))
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(usage.map { "Reported \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
        }
    }
}
