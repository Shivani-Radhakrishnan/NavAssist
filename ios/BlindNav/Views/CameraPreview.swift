import ARKit
import SwiftUI

/// Live view of the AR session's camera, for the sighted helper. It shares the app's
/// one ARSession (it doesn't start its own), and the yellow dots are the feature points
/// ARKit is tracking: lots of dots = good tracking, few dots = point at more detail.
struct CameraPreview: UIViewRepresentable {
    let session: ARSession
    var showTrackingDots = true

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.debugOptions = showTrackingDots ? [.showFeaturePoints] : []
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Camera view"
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session { view.session = session }
        view.debugOptions = showTrackingDots ? [.showFeaturePoints] : []
    }
}
