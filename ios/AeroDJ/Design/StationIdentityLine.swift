import SwiftUI

/// Station name and the DJ personality that is actually in effect.
///
/// The personality title is the preset name. The detail is `DJPersonality.honestDescription`
/// (length cap and "same voice"), so the line does not describe a different voice or style.
/// It never says On Air. That badge stays on `DJStatusLine`, and only while speaking.
struct StationIdentityLine: View {
    let stationName: String
    var personalityTitle: String?
    var personalityDetail: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    name
                    if personalityTitle != nil {
                        Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                        personality
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    name
                    personality
                }
            }
            if let personalityDetail {
                Text(personalityDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var name: some View {
        Text(stationName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var personality: some View {
        if let personalityTitle {
            Text(personalityTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var accessibilityText: String {
        var parts = ["Station \(stationName)"]
        if let personalityTitle { parts.append("DJ personality \(personalityTitle)") }
        if let personalityDetail { parts.append(personalityDetail) }
        return parts.joined(separator: ". ")
    }
}
