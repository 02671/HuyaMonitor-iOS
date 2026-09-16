import SwiftUI

struct SearchSheet: View {

    @EnvironmentObject var viewModel: MonitorViewModel

    let onPick: (SearchResult) -> Void
    let onClose: () -> Void

    @State private var searchTask: Task<Void, Never>?

    private var results: [SearchResult] { viewModel.searchResults }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Theme.muted)
                        TextField("主播名", text: $viewModel.searchKeyword)
                            .foregroundColor(Theme.text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { viewModel.runSearch() }
                            .onChange(of: viewModel.searchKeyword) { _ in
                                searchTask?.cancel()
                                searchTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    guard !Task.isCancelled else { return }
                                    viewModel.runSearch()
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                    .cornerRadius(9)

                    HStack {
                        Text(viewModel.searchStatus)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.muted)
                        Spacer()
                        if viewModel.searching {
                            ProgressView().controlSize(.small)
                        }
                    }

                    List {
                        ForEach(results) { result in
                            HStack {
                                Text(result.roomId)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(result.liveOn ? ConnectionPhase.on.color : Theme.text)
                                    .frame(width: 96, alignment: .leading)
                                Text(result.nick.isEmpty ? "未知主播" : result.nick)
                                    .foregroundColor(result.liveOn ? ConnectionPhase.on.color : Theme.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(result.liveOn ? "开播" : "未开播")
                                    .font(.system(size: 12))
                                    .foregroundColor(result.liveOn ? ConnectionPhase.on.color : Theme.muted)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(result) }
                            .listRowBackground(Theme.card)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                .padding(12)
            }
            .navigationTitle("搜索主播")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        searchTask?.cancel()
                        onClose()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
