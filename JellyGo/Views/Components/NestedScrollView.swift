import SwiftUI

/// A fixed-height scrollable container that:
/// - Allows downward bounce at its own bottom edge
/// - Prevents upward bounce at its own top edge (clamps to 0)
/// - Disables bottom bounce on the parent (outer) ScrollView
struct NestedScrollView<Content: View>: UIViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.alwaysBounceVertical = true
        context.coordinator.scrollView = scrollView

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        context.coordinator.hostController = host

        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        // Disable bottom bounce on the parent (outer) ScrollView
        DispatchQueue.main.async {
            var view: UIView? = scrollView.superview
            while let v = view {
                if let parentSV = v as? UIScrollView, parentSV !== scrollView {
                    // Keep top bounce (for parallax), disable bottom bounce
                    // UIScrollView doesn't have per-edge bounce, so we use contentInsetAdjustmentBehavior
                    // and handle via delegate on the coordinator
                    context.coordinator.parentScrollView = parentSV
                    parentSV.delegate = context.coordinator.parentDelegate
                    break
                }
                view = v.superview
            }
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostController?.rootView = content()
    }

    class ParentScrollDelegate: NSObject, UIScrollViewDelegate {
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offsetY = scrollView.contentOffset.y
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            // Prevent bottom bounce — clamp at max
            if maxOffset > 0 && offsetY > maxOffset {
                scrollView.contentOffset.y = maxOffset
            }
        }
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var parentScrollView: UIScrollView?
        var hostController: UIHostingController<Content>?
        let parentDelegate = ParentScrollDelegate()

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offsetY = scrollView.contentOffset.y
            // Prevent upward bounce (top edge) — clamp to 0
            if offsetY < 0 {
                scrollView.contentOffset.y = 0
            }
        }
    }
}
