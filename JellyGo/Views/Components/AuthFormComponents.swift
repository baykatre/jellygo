import SwiftUI

// Shared pieces of the server-entry form (welcome screen), so other small forms such as
// Quick Connect look exactly like it.

/// Uppercase caption above a translucent rounded card.
struct AuthFormCard<Content: View>: View {
    let header: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            content()
                .padding(12)
                .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        }
    }
}

/// Single-line input with a small leading chip, as in the server address field.
struct AuthInputField: View {
    let icon: String
    let chip: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var monospaced = false
    var isError = false
    var isFocused = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(chip).font(.system(.caption2, design: .monospaced).weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.08)))
            .padding(.leading, 10)
            .padding(.trailing, 6)

            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.25)))
                .textFieldStyle(.plain)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(.white)
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                .tint(JGColor.brand)
                .padding(.trailing, 14)
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isError ? JGColor.danger.opacity(0.5)
                                      : isFocused ? JGColor.brand.opacity(0.4) : .white.opacity(0.08),
                                      lineWidth: 1)
                )
        )
    }
}

/// Error line under a field.
struct AuthErrorLine: View {
    let message: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").font(.caption2)
            Text(message).font(.caption)
        }
        .foregroundStyle(JGColor.danger.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// White capsule primary button, as "Connect".
struct AuthPrimaryButton: View {
    let title: String
    let systemImage: String
    var isLoading = false
    var isDone = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.black)
                } else if isDone {
                    Image(systemName: "checkmark")
                } else {
                    Image(systemName: systemImage)
                    Text(title)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? .black : .black.opacity(0.3))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background { Capsule().fill(isEnabled ? .white : .white.opacity(0.4)) }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }
}

/// Sizes a bottom sheet to its content instead of opening it full screen, and gives it the
/// raised sheet surface. Re-measures when the content changes (e.g. server step → login).
private struct FittedSheet: ViewModifier {
    @State private var height: CGFloat = 320

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                if abs(new - height) > 1 { height = new }
            }
            .presentationDetents([.height(height)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
            .presentationBackground(JGColor.sheet)
    }
}

extension View {
    func fittedSheet() -> some View { modifier(FittedSheet()) }
}
