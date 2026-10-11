import SwiftUI

struct CalibrationOverlay: View {
    @ObservedObject var service: HardwareTouchService
    var body: some View {
        GeometryReader { geo in
            if let session = service.guidedCalibration {
                ZStack {
                    Color.black.opacity(0.97)
                    VStack(spacing: 14) {
                        Text("Calibrate touch").font(.largeTitle.bold())
                        if let error = session.error {
                            Text(error).multilineTextAlignment(.center).frame(maxWidth: 600)
                            Button("Try again") { service.beginGuidedCalibration() }
                                .controlSize(.large)
                                .touchZone(
                                    id: HardwareTouchService.calibrationRetryZone, registry: service.zoneRegistry
                                ) {
                                    Task { @MainActor in service.beginGuidedCalibration() }
                                }
                        } else {
                            Text(
                                session.step == 4
                                    ? "Final check: hold the center target"
                                    : "Hold the highlighted target · \(session.step + 1) of 4"
                            )
                            .font(.title2)
                            Text(
                                session.awaitingRelease
                                    ? "Lift your finger before the next target."
                                    : "Touch the crosshair from your normal seated position and hold still.")
                        }
                        Button("Cancel — keep current calibration") { service.cancelGuidedCalibration() }
                            .keyboardShortcut(.cancelAction)
                            .controlSize(.large)
                            .touchZone(id: HardwareTouchService.calibrationCancelZone, registry: service.zoneRegistry) {
                                Task { @MainActor in service.cancelGuidedCalibration() }
                            }
                    }
                    .padding(24)
                    .offset(y: session.step == 4 ? -geo.size.height * 0.25 : 0)
                    if session.error == nil {
                        let target = GuidedCalibration.targets[min(session.step, 4)]
                        ZStack {
                            Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                            Circle().trim(from: 0, to: min(session.progress, 1)).stroke(.green, lineWidth: 6)
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "plus").font(.system(size: 28, weight: .light))
                        }
                        .frame(width: 64, height: 64)
                        .position(x: geo.size.width * target.x, y: geo.size.height * target.y)
                        .allowsHitTesting(false)
                    }
                }.foregroundStyle(.white)
            }
            Color.clear.frame(width: 0, height: 0)
                .onAppear { service.updateRenderBounds(CGRect(origin: .zero, size: geo.size)) }
                .onChange(of: geo.size) { _, size in
                    if service.guidedCalibration != nil { service.cancelGuidedCalibration() }
                    service.updateRenderBounds(CGRect(origin: .zero, size: size))
                }
        }.allowsHitTesting(service.guidedCalibration != nil)
    }
}
