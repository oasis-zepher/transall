import SwiftUI

struct PreviewGridView: View {
  let pages: [PreviewPage]

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        SectionLabel(text: "PDF Preview")
        Spacer()
        Text("前 \(pages.count) 页")
          .font(.system(size: 9))
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
                    .font(.system(size: 28, weight: .light))
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

              Text("第 \(page.page) 页")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TransallTheme.muted)
            }
          }
        }
        .padding(.bottom, 7)
      }
      .scrollIndicators(.visible)
    }
  }
}
