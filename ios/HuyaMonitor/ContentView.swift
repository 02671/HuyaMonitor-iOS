import SwiftUI

enum Theme {
    static let bg = Color(red: 0.071, green: 0.078, blue: 0.102)
    static let panel = Color(red: 0.106, green: 0.122, blue: 0.165)
    static let card = Color(red: 0.137, green: 0.157, blue: 0.212)
    static let line = Color(red: 0.196, green: 0.220, blue: 0.290)
    static let text = Color(red: 0.910, green: 0.925, blue: 0.949)
    static let muted = Color(red: 0.545, green: 0.576, blue: 0.655)
    static let name = Color(red: 0.604, green: 0.659, blue: 0.780)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.36)
    static let accent = Color(red: 0.298, green: 0.553, blue: 1.0)
}

struct PillButton: View {
    let title: String
    var background: Color
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(background)
                .foregroundColor(foreground)
                .cornerRadius(9)
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {

    @EnvironmentObject var viewModel: MonitorViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showHistory = false
    @State private var showSearch = false
    @State private var showVolume = false

    private var combinedPhase: ConnectionPhase {
        if viewModel.danmuPhase == .on && viewModel.audioPhase == .on { return .on }
        if viewModel.danmuPhase == .off && viewModel.audioPhase == .off { return .off }
        return .busy
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 10) {
                toolbar
                DanmakuListView(lines: viewModel.lines)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                viewModel.handleForeground()
            case .background:
                viewModel.handleBackground()
            default:
                break
            }
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(onPick: { item in
                viewModel.selectHistory(item)
                showHistory = false
            })
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(onPick: { result in
                viewModel.pickSearch(result)
                showSearch = false
            }, onClose: {
                showSearch = false
                viewModel.resetSearch()
            })
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showVolume) {
            VolumeSheet()
                .environmentObject(viewModel)
        }
        .alert("提示", isPresented: alertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("房号")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.muted)
                HStack(spacing: 6) {
                    TextField("输入虎牙房号", text: $viewModel.roomText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundColor(Theme.text)
                        .submitLabel(.go)
                        .onSubmit { viewModel.connectAll() }
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(Theme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                .cornerRadius(9)
                .frame(maxWidth: .infinity)
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 40, height: 38)
                        .background(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                        .cornerRadius(9)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                PillButton(title: "启动", background: combinedPhase.color) {
                    viewModel.connectAll()
                }
                PillButton(title: "弹幕", background: viewModel.danmuPhase.color) {
                    viewModel.toggleDanmaku()
                }
                PillButton(title: "音频", background: viewModel.audioPhase.color) {
                    viewModel.toggleAudio()
                }
                PillButton(title: "清屏", background: Theme.line, foreground: Theme.text) {
                    viewModel.clearDanmaku()
                }
                PillButton(title: "音量", background: Theme.line, foreground: Theme.text) {
                    showVolume = true
                }
            }

            if !viewModel.audioTitle.isEmpty && viewModel.audioPhase != .off {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundColor(Theme.accent)
                    Text(viewModel.audioQuality.isEmpty
                         ? "正在播放：\(viewModel.audioTitle)"
                         : "正在播放：\(viewModel.audioTitle)（\(viewModel.audioQuality)）")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                    Spacer()
                }
            }

            if !viewModel.danmakuDiagnostic.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(Theme.danger)
                    Text("弹幕诊断：\(viewModel.danmakuDiagnostic)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Theme.panel)
        .cornerRadius(12)
    }
}
