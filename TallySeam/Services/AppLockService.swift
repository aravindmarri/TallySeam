import Foundation
import LocalAuthentication
import Observation

/// Abstraction over LocalAuthentication so the lock logic can be unit-tested.
protocol DeviceAuthenticating: Sendable {
    /// True when Face ID, Touch ID or a device passcode is set up.
    func canAuthenticate() -> Bool
    /// Asks for Face ID / Touch ID, falling back to the device passcode.
    func authenticate(reason: String) async -> Bool
    var biometryName: String { get }
}

struct LocalDeviceAuthenticator: DeviceAuthenticating {
    func canAuthenticate() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }
}

/// App lock state. When enabled, the app starts locked and locks again whenever it goes to the background.
/// The decision to require unlock is stored in `AppSettings.requireBiometricUnlock`.
@MainActor
@Observable
final class AppLockController {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private let authenticator: any DeviceAuthenticating

    init(isEnabled: Bool, authenticator: any DeviceAuthenticating = LocalDeviceAuthenticator()) {
        self.authenticator = authenticator
        // If the device passcode was removed, iOS can no longer verify the owner, so the lock can't be
        // enforced. Locking anyway would shut the user out of their own data, so it is not applied.
        self.isLocked = isEnabled && authenticator.canAuthenticate()
    }

    var biometryName: String { authenticator.biometryName }
    var isAvailable: Bool { authenticator.canAuthenticate() }

    func lockIfEnabled(_ isEnabled: Bool) {
        if isEnabled && authenticator.canAuthenticate() { isLocked = true }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await authenticator.authenticate(reason: "Unlock your financial data") {
            isLocked = false
        } else {
            DiagnosticsService.shared.log(.authenticationFailed)
        }
    }

    /// Turning the lock on or off requires the owner to authenticate first.
    func confirmChange() async -> Bool {
        guard authenticator.canAuthenticate() else { return false }
        return await authenticator.authenticate(reason: "Confirm it's you to change the app lock")
    }
}
