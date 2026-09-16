import SwiftUI

struct DanmakuListView: View {

    let lines: [DanmakuLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.user)
                                .foregroundColor(line.isSystem ? Theme.danger : Theme.name)
                            Text(line.text)
                                .foregroundColor(line.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.id)
                    }
                }
                .padding(10)
            }
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .cornerRadius(12)
            .onChange(of: lines.count) { _ in
                guard let last = lines.last else { return }
                withAnimation(.linear(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay {
                if lines.isEmpty {
                    Text("输入房号后点「启动」，弹幕会显示在这里")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
