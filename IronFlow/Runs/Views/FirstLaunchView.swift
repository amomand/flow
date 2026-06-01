import SwiftUI

struct FirstLaunchView: View {
    @Environment(\.theme) private var theme
    let settings: AppSettings
    let onComplete: () -> Void

    @State private var startDate: Date = AppSettings.defaultStartDate
    @State private var requesting = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("$ flow runs init")
                            .terminalFont(22, weight: .bold)
                            .foregroundColor(theme.cyan)
                        Text("// flick back through your runs")
                            .terminalFont(12)
                            .foregroundColor(theme.comment)
                    }

                    SectionHeader(text: "PERMISSIONS")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Flow reads running and cycling workouts from Apple Health.")
                            .terminalFont(13)
                            .foregroundColor(theme.fg)
                        Text("Read-only. Never writes back.")
                            .terminalFont(12)
                            .foregroundColor(theme.comment)
                    }
                    .terminalCard()

                    SectionHeader(text: "START FROM")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show me runs from…")
                            .terminalFont(13)
                            .foregroundColor(theme.fg)
                        DatePicker("", selection: $startDate, displayedComponents: [.date])
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .colorScheme(.dark)
                            .accentColor(theme.cyan)
                    }
                    .terminalCard()

                    if let errorText {
                        Text("[error] \(errorText)")
                            .terminalFont(12)
                            .foregroundColor(theme.red)
                    }

                    Button(action: begin) {
                        Text(requesting ? "[ requesting… ]" : "[ continue ]")
                    }
                    .buttonStyle(TerminalButtonStyle(color: theme.cyan))
                    .disabled(requesting)
                }
                .padding(20)
            }
        }
    }

    private func begin() {
        requesting = true
        errorText = nil
        Task {
            do {
                try await HealthKitService.shared.requestAuthorization()
                await MainActor.run {
                    settings.startDate = startDate
                    settings.hasOnboarded = true
                    requesting = false
                    onComplete()
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    requesting = false
                }
            }
        }
    }
}
