import SwiftUI

/// 备份列表里的药丸状（Capsule）小按钮，用于「从备份恢复」「删除」等行内操作。
struct BackupPillButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(effectiveTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(effectiveTint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(effectiveTint.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
    }

    private var effectiveTint: Color { isDisabled ? .secondary : tint }
}
