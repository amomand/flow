import SwiftUI

struct TerminalFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: .monospaced))
    }
}

extension View {
    func terminalFont(_ size: CGFloat = 16, weight: Font.Weight = .regular) -> some View {
        modifier(TerminalFont(size: size, weight: weight))
    }
}

struct TerminalButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .terminalFont(14, weight: .bold)
            .foregroundColor(configuration.isPressed ? theme.bg : color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color, lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(configuration.isPressed ? color : Color.clear)
                    )
            )
    }
}

struct TerminalCardModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.comment.opacity(0.3), lineWidth: 1)
                    )
            )
    }
}

extension View {
    func terminalCard() -> some View {
        modifier(TerminalCardModifier())
    }
}

struct SectionHeader: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text("// \(text)")
            .terminalFont(12, weight: .semibold)
            .foregroundColor(theme.purple)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowScreenHeader<Actions: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String
    let actions: Actions

    init(title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("// \(title)")
                    .terminalFont(22, weight: .bold)
                    .foregroundColor(theme.blue)

                Text(subtitle)
                    .terminalFont(13)
                    .foregroundColor(theme.comment)
            }

            Spacer()

            actions
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
