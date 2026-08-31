import AteKit
import SwiftUI

/// Placeholder root for the walking skeleton. The first real flow (Feed) replaces this.
struct ContentView: View {
    let environment: Result<AteEnvironment, Error>

    var body: some View {
        VStack(spacing: Theme.Spacing.regular) {
            Text("Ate — skeleton")
                .font(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            switch environment {
            case .success(let environment):
                Text(BuildStamp(environment: environment.name)
                    .summary(supabaseHost: environment.supabaseURL.host()))
                    .font(Theme.Text.detail)
                    .foregroundStyle(Theme.Color.textSecondary)
            case .failure(let error):
                Label(String(describing: error), systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.destructive)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Spacing.comfortable)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.background)
    }
}

#Preview("Staging") {
    ContentView(environment: .success(AteEnvironment(
        name: .staging,
        supabaseURL: URL(string: "https://cvoitgoaosofkougmarn.supabase.co")!,
        supabaseKey: "sb_publishable_preview"
    )))
}

#Preview("Misconfigured") {
    ContentView(environment: .failure(AteEnvironment.ConfigurationError.missing(key: "SUPABASE_URL")))
}
