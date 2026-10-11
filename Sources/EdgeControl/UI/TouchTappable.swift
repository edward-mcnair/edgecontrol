import SwiftUI

/// View modifier that makes any view tappable via both mouse click AND HID touch input.
/// Registers the view's frame as a touch zone in TouchZoneRegistry for hardware touch support.
struct TouchTappable: ViewModifier {
    let id: String
    let registry: TouchZoneRegistry
    let action: @Sendable () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            let frame = geo.frame(in: .named(TouchCoordinate.name))
                            registry.register(id: id, frame: frame, action: action)
                        }
                        .onChange(of: geo.frame(in: .named(TouchCoordinate.name))) { _, newFrame in
                            registry.register(id: id, frame: newFrame, action: action)
                        }
                }
            )
            .onDisappear {
                registry.unregister(id: id)
            }
    }
}

/// Registers a view's frame as a hardware-touch zone without adding a tap
/// gesture, for controls (SwiftUI Buttons) that already handle mouse and keyboard.
struct TouchZoneRegistration: ViewModifier {
    let id: String
    let registry: TouchZoneRegistry
    let action: @Sendable () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            registry.register(
                                id: id, frame: geo.frame(in: .named(TouchCoordinate.name)), action: action)
                        }
                        .onChange(of: geo.frame(in: .named(TouchCoordinate.name))) { _, frame in
                            registry.register(id: id, frame: frame, action: action)
                        }
                }
            )
            .onDisappear { registry.unregister(id: id) }
    }
}

extension View {
    /// Make an existing control reachable by hardware touch taps.
    func touchZone(id: String, registry: TouchZoneRegistry, action: @escaping @Sendable () -> Void) -> some View {
        modifier(TouchZoneRegistration(id: id, registry: registry, action: action))
    }

    /// Make this view tappable via both mouse and HID touch input.
    func touchTappable(id: String, registry: TouchZoneRegistry, action: @escaping @Sendable () -> Void) -> some View {
        modifier(TouchTappable(id: id, registry: registry, action: action))
    }
}
