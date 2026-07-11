import SwiftUI

/// Full-screen photo viewer, Photos-app behaviour:
/// swipe between images · pinch to zoom · double-tap to zoom · swipe down
/// to dismiss (when not zoomed).
struct PhotoViewer: View {
    let photos: [VisitPhoto]
    let visitID: String
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(min(abs(dragOffset) / 600, 0.5)))
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { position, photo in
                    ZoomableImage(
                        image: PhotoStore.load(photo, visitID: visitID),
                        onDismissDrag: { offset in dragOffset = offset },
                        onDismiss: { dismiss() }
                    )
                    .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .offset(y: dragOffset)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.trailing, 16)
                }
                if photos.indices.contains(index) {
                    let kind = photos[index].kind
                    Text(kind == .visualization ? "FINISHED"
                         : kind == .preparation ? "PREPARED" : kind.label.uppercased())
                        .font(.footnote.weight(.bold))
                        .kerning(1.0)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            kind.isRender ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                        .foregroundStyle(kind.isRender ? .black : .white)
                        .id(index) // re-animate on page change
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer()
            }
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.2), value: index)
        }
        .statusBarHidden()
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { appeared = true } }
    }

    @State private var appeared = false
}

/// One zoomable page. UIScrollView gives the exact pinch/double-tap/pan
/// physics of the Photos app — SwiftUI gestures can't match it.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    let onDismissDrag: (CGFloat) -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.dismissPanned(_:))
        )
        dismissPan.delegate = context.coordinator
        scroll.addGestureRecognizer(dismissPan)

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImage
        weak var imageView: UIImageView?

        init(_ parent: ZoomableImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(
                    width: scroll.bounds.width / 2.5,
                    height: scroll.bounds.height / 2.5
                )
                scroll.zoom(
                    to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                               width: size.width, height: size.height),
                    animated: true
                )
            }
        }

        /// Swipe-down-to-dismiss, active only at 1x zoom (like Photos).
        @objc func dismissPanned(_ gesture: UIPanGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, scroll.zoomScale <= 1.01 else { return }
            let translation = gesture.translation(in: scroll).y
            switch gesture.state {
            case .changed where translation > 0:
                parent.onDismissDrag(translation)
            case .ended, .cancelled:
                if translation > 140 || gesture.velocity(in: scroll).y > 900 {
                    parent.onDismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { parent.onDismissDrag(0) }
                }
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
