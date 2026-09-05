import SwiftUI

struct PreviewGridView: View {
  let pages: [PreviewPage]
  let inspectPage: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        SectionLabel(text: "PDF Preview")
        Spacer()
        Text("前 \(pages.count) 页")
          .font(.caption2)
          .foregroundStyle(TransallTheme.muted)
      }

      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 10) {
          ForEach(pages) { page in
            VStack(alignment: .leading, spacing: 5) {
              AsyncImage(url: URL(string: page.url)) { phase in
                switch phase {
                case .empty:
                  ProgressView()
                    .controlSize(.small)
                    .frame(width: 142, height: 190)
                case .success(let image):
                  image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 142, height: 190)
                    .background(Color.white)
                case .failure:
                  Image(systemName: "doc.richtext")
                    .font(.title.weight(.light))
                    .foregroundStyle(TransallTheme.lineStrong)
                    .frame(width: 142, height: 190)
                @unknown default:
                  EmptyView()
                }
              }
              .overlay {
                Rectangle().stroke(TransallTheme.line, lineWidth: 1)
              }
              .shadow(color: TransallTheme.ink.opacity(0.09), radius: 6, y: 3)
              .accessibilityLabel("第 \(page.page) 页预览")

              Button("第 \(page.page) 页 · 放大") { inspectPage(page.page) }
                .font(.caption2.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(TransallTheme.target)
                .accessibilityLabel("放大检查第 \(page.page) 页")
            }
          }
        }
        .padding(.bottom, 7)
      }
      .scrollIndicators(.visible)
    }
  }
}
