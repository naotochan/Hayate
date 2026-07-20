import SwiftUI

/// Shared panel chrome used by Settings and other preference-style surfaces.
/// Canonical layout reference: `SettingsView` (sidebar + content). Tokens live
/// in `HayateTheme`. See `.cursor/rules/ui-design.mdc`.
enum HayateChrome {
    static let cornerRadius: CGFloat = 10
    static let rowHorizontalPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 12
    static let groupSpacing: CGFloat = 20
    static let pageHorizontalPadding: CGFloat = 28
    static let pageVerticalPadding: CGFloat = 24
    static let sidebarWidth: CGFloat = 220

    // MARK: - Page title

    struct PageTitle: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(HayateTheme.fg(0.95))
        }
    }

    // MARK: - Group

    /// Uppercase section label + rounded wash container for rows.
    struct Group<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HayateTheme.fg(0.42))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .padding(.leading, 4)

                VStack(spacing: 0) {
                    content
                }
                .background(
                    RoundedRectangle(cornerRadius: HayateChrome.cornerRadius, style: .continuous)
                        .fill(HayateTheme.wash(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HayateChrome.cornerRadius, style: .continuous)
                        .strokeBorder(HayateTheme.wash(0.06), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Row

    /// Title (+ optional subtitle) on the left; control on the right.
    struct Row<Trailing: View>: View {
        let title: String
        let subtitle: String?
        @ViewBuilder var trailing: Trailing

        init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
            self.title = title
            self.subtitle = subtitle
            self.trailing = trailing()
        }

        var body: some View {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(HayateTheme.fg(0.92))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundColor(HayateTheme.fg(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing
            }
            .padding(.horizontal, HayateChrome.rowHorizontalPadding)
            .padding(.vertical, HayateChrome.rowVerticalPadding)
        }
    }

    struct ToggleRow: View {
        let title: String
        let subtitle: String
        @Binding var isOn: Bool

        var body: some View {
            Row(title: title, subtitle: subtitle) {
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    struct Divider: View {
        var body: some View {
            Rectangle()
                .fill(HayateTheme.separator)
                .frame(height: 1)
                .padding(.leading, HayateChrome.rowHorizontalPadding)
        }
    }

    // MARK: - Sidebar

    struct SearchField: View {
        let placeholder: String
        @Binding var text: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(HayateTheme.fg(0.35))
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HayateTheme.wash(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(HayateTheme.wash(0.08), lineWidth: 1)
            )
        }
    }

    struct SidebarItem: View {
        let title: String
        let systemImage: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundColor(isSelected ? HayateTheme.fg(0.95) : HayateTheme.fg(0.62))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? HayateTheme.wash(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
