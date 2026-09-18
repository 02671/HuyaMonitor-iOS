import SwiftUI
import UIKit

struct DanmakuListView: View {

    let lines: [DanmakuLine]

    var body: some View {
        DanmakuScrollRepresentable(lines: lines)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .cornerRadius(12)
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

private struct DanmakuScrollRepresentable: UIViewRepresentable {

    let lines: [DanmakuLine]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.allowsSelection = false
        table.showsVerticalScrollIndicator = true
        table.estimatedRowHeight = 28
        table.rowHeight = UITableView.automaticDimension
        table.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 36, right: 0)
        table.scrollIndicatorInsets = UIEdgeInsets(top: 8, left: 0, bottom: 36, right: 0)
        table.register(DanmakuCell.self, forCellReuseIdentifier: DanmakuCell.reuseId)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userTouched))
        tap.cancelsTouchesInView = false
        table.addGestureRecognizer(tap)
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        context.coordinator.apply(lines)
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UIScrollViewDelegate {

        var items: [DanmakuLine] = []
        weak var table: UITableView?
        private var followLatest = true
        private var resumeItem: DispatchWorkItem?
        private var isProgrammaticScroll = false

        func apply(_ lines: [DanmakuLine]) {
            let oldCount = items.count
            let oldLast = items.last?.id
            items = lines
            guard let table else { return }
            let offset = table.contentOffset
            table.reloadData()
            if followLatest, let last = lines.last, lines.count != oldCount || last.id != oldLast {
                scrollToBottom(animated: oldCount > 0)
            } else if !followLatest {
                table.layoutIfNeeded()
                table.setContentOffset(offset, animated: false)
            }
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            items.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: DanmakuCell.reuseId, for: indexPath) as! DanmakuCell
            if items.indices.contains(indexPath.row) {
                cell.configure(items[indexPath.row])
            }
            return cell
        }

        @objc func userTouched() {
            if isProgrammaticScroll, let table {
                table.setContentOffset(table.contentOffset, animated: false)
            }
            pauseFollow()
            armResume()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if isProgrammaticScroll {
                scrollView.setContentOffset(scrollView.contentOffset, animated: false)
                isProgrammaticScroll = false
            }
            pauseFollow()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                armResume()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if !isProgrammaticScroll {
                armResume()
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.isTracking || scrollView.isDragging {
                pauseFollow()
            }
        }

        private func pauseFollow() {
            followLatest = false
            isProgrammaticScroll = false
            resumeItem?.cancel()
            resumeItem = nil
        }

        private func armResume() {
            resumeItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.followLatest = true
                self.scrollToBottom(animated: true)
            }
            resumeItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }

        private func scrollToBottom(animated: Bool) {
            guard let table, !items.isEmpty else { return }
            isProgrammaticScroll = true
            let index = IndexPath(row: items.count - 1, section: 0)
            table.scrollToRow(at: index, at: .bottom, animated: animated)
            if !animated {
                isProgrammaticScroll = false
            }
        }
    }
}

private final class DanmakuCell: UITableViewCell {

    static let reuseId = "danmaku-cell"

    private let userLabel = UILabel()
    private let textLabelView = UILabel()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        userLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        userLabel.setContentHuggingPriority(.required, for: .horizontal)
        userLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textLabelView.font = .systemFont(ofSize: 15, weight: .semibold)
        textLabelView.numberOfLines = 0

        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(userLabel)
        stack.addArrangedSubview(textLabelView)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ line: DanmakuLine) {
        userLabel.text = line.user
        textLabelView.text = line.text
        userLabel.textColor = line.isSystem
            ? UIColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1)
            : UIColor(red: 0.604, green: 0.659, blue: 0.780, alpha: 1)
        textLabelView.textColor = line.color
    }
}
