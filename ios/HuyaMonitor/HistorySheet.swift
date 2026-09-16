import SwiftUI

struct HistorySheet: View {

    @EnvironmentObject var viewModel: MonitorViewModel
    @Environment(\.dismiss) private var dismiss

    let onPick: (HistoryItem) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if viewModel.history.isEmpty {
                    Text("暂无历史记录")
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.history) { item in
                            HStack {
                                Text(item.label)
                                    .foregroundColor(Theme.text)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(item) }
                                Spacer()
                                Button {
                                    viewModel.deleteHistory(item.roomId)
                                } label: {
                                    Text("删除")
                                        .foregroundColor(Theme.danger)
                                }
                                .buttonStyle(.borderless)
                            }
                            .listRowBackground(Theme.card)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("历史房号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
