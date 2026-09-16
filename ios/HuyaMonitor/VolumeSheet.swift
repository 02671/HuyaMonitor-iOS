import SwiftUI

struct VolumeSheet: View {

    @EnvironmentObject var viewModel: MonitorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 22) {
                    Text("\(Int(viewModel.volume * 100))%")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(Theme.text)
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .foregroundColor(Theme.muted)
                        Slider(value: Binding(
                            get: { viewModel.volume },
                            set: { viewModel.setVolume($0) }
                        ), in: 0...1)
                        .tint(Theme.accent)
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundColor(Theme.muted)
                    }
                    Text("只调整本应用的音量，不影响系统其它声音")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .navigationTitle("音量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
