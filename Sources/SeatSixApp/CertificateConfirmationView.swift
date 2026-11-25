import Foundation
import SwiftUI
import SeatSixCore

/// A login attempt is immutable so a late handshake can never approve newly edited input.
struct ServerLoginAttempt: Equatable {
    let kind: ServerKind
    let address: String
    let username: String
    let password: String
    let allowHTTP: Bool
    let compatibilityMode: Bool
    let deviceID: String
}

struct ServerLoginServices {
    var authenticate: (ServerLoginAttempt, CertificatePin?) async throws -> AuthenticatedServer
    var inspect: (URL) async throws -> CertificateInspection
    var libraries: (AuthenticatedServer, String) async throws -> [MediaLibrary]

    static let live = ServerLoginServices(authenticate: { attempt, pin in
        try await MediaServerClient.authenticate(kind: attempt.kind, address: attempt.address,
            username: attempt.username, password: attempt.password, allowInsecureHTTP: attempt.allowHTTP,
            deviceID: attempt.deviceID, compatibilityMode: attempt.compatibilityMode, certificatePin: pin)
    }, inspect: { try await CertificateInspector.inspect(url: $0) }, libraries: { result, deviceID in
        try await MediaServerClient(connection: result.connection, token: result.token, deviceID: deviceID).libraries()
    })
}

/// A compatible service uses the existing Emby subset, not a separate native API.
enum ServerLoginSource: String, CaseIterable, Identifiable {
    case emby, jellyfin, compatible
    var id: Self { self }
    var name: String {
        switch self {
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .compatible: return "Emby 兼容"
        }
    }
}

@MainActor
final class ServerLoginState: ObservableObject {
    struct Challenge: Identifiable {
        let id: UUID
        let inspection: CertificateInspection
        let previousFingerprint: String?
        fileprivate let attempt: ServerLoginAttempt
    }
    @Published var kind: ServerKind = .emby { didSet { if kind != oldValue { inputChanged(clearPin: true) } } }
    @Published var addressForm = ServerAddressForm() { didSet { if addressForm != oldValue { inputChanged(clearPin: true) } } }
    @Published var username = "" { didSet { if username != oldValue { inputChanged() } } }
    @Published var password = "" { didSet { if password != oldValue { inputChanged() } } }
    @Published var compatibilityMode = false { didSet { if compatibilityMode != oldValue { inputChanged() } } }
    @Published private(set) var working = false
    @Published var error: String?
    @Published private(set) var authenticated: AuthenticatedServer?
    @Published private(set) var libraries: [MediaLibrary] = []
    @Published private(set) var challenge: Challenge?
    private var pin: CertificatePin?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let deviceID: String
    private let services: ServerLoginServices
    private var isInitializing = true
    private var clearingPassword = false

    /// Compatibility accessors keep one editable address model as the source of truth.
    var address: String {
        get { addressForm.preview ?? addressForm.host }
        set { addressForm.updateHost(newValue) }
    }
    var allowHTTP: Bool {
        get { !addressForm.useHTTPS }
        set { addressForm.useHTTPS = !newValue }
    }
    var source: ServerLoginSource {
        get { kind == .jellyfin ? .jellyfin : (compatibilityMode ? .compatible : .emby) }
        set {
            kind = newValue == .jellyfin ? .jellyfin : .emby
            compatibilityMode = newValue == .compatible
        }
    }
    var validationMessage: String? { addressForm.validationMessage }
    var canSubmit: Bool {
        !working && challenge == nil && attempt != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applyUGREENPreset() {
        source = .compatible
        var updated = addressForm
        // Commit an address still being typed before applying the explicit preset.
        updated.updateHost(updated.host)
        updated.useHTTPS = true; updated.port = "9443"; updated.path = "/emby"
        addressForm = updated
    }

    init(deviceID: String, existing: ServerConnection? = nil, services: ServerLoginServices = .live) {
        self.deviceID = deviceID; self.services = services
        if let existing {
            kind = existing.kind; addressForm = ServerAddressForm(url: existing.baseURL); username = existing.username
            compatibilityMode = existing.compatibilityMode
            pin = existing.certificatePin
        }
        isInitializing = false
    }

    private var attempt: ServerLoginAttempt? {
        guard let endpoint = try? addressForm.endpoint() else { return nil }
        return ServerLoginAttempt(kind: kind, address: endpoint.baseURL.absoluteString,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
            allowHTTP: allowHTTP, compatibilityMode: kind == .emby && compatibilityMode, deviceID: deviceID)
    }
    private func inputChanged(clearPin: Bool = false) {
        guard !isInitializing, !clearingPassword else { return }
        invalidate(); if clearPin { pin = nil }; authenticated = nil; libraries = []; error = nil
    }
    private func invalidate() {
        generation = UUID(); task?.cancel(); task = nil; working = false; challenge = nil
    }
    private func clearPassword() {
        clearingPassword = true; password = ""; clearingPassword = false
    }
    func cancel() { invalidate(); pin = nil; clearPassword(); authenticated = nil; libraries = [] }
    func back() { invalidate(); authenticated = nil; libraries = []; error = nil }
    func cancelTrust() { invalidate(); pin = nil; error = "未信任此证书，未继续登录。" }

    func login() {
        guard !working, challenge == nil else { return }
        guard let submitted = attempt else {
            error = validationMessage ?? "请输入服务器地址。"; return
        }
        guard !submitted.username.isEmpty else { error = "请输入服务器用户名。"; return }
        begin(submitted, certificatePin: pin)
    }
    func approve(_ challengeID: UUID) {
        guard let candidate = challenge, candidate.id == challengeID, candidate.attempt == attempt,
              candidate.inspection.canApprove else { return }
        do {
            let approved = try candidate.inspection.makePin()
            challenge = nil; pin = approved
            begin(candidate.attempt, certificatePin: approved)
        } catch { self.error = error.localizedDescription }
    }
    private func begin(_ submitted: ServerLoginAttempt, certificatePin: CertificatePin?) {
        invalidate()
        let requestID = generation
        working = true; error = nil
        task = Task {
            do {
                var result = try await services.authenticate(submitted, certificatePin)
                try Task.checkCancellation()
                guard generation == requestID, attempt == submitted else { return }
                if submitted.compatibilityMode, result.connection.name == submitted.kind.name,
                   let host = URL(string: submitted.address)?.host {
                    // The compatibility API has no public server-name discovery. Its
                    // protocol fallback is not a useful name when adding multiple NASes.
                    result.connection.name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
                }
                let available = try await services.libraries(result, deviceID)
                try Task.checkCancellation()
                guard generation == requestID, attempt == submitted else { return }
                authenticated = result; libraries = available; working = false; clearPassword()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == requestID, attempt == submitted else { return }
                guard Self.isCertificateFailure(error) else {
                    self.error = error.localizedDescription; working = false; return
                }
                do {
                    let endpoint = try ServerEndpoint(address: submitted.address, allowInsecureHTTP: submitted.allowHTTP)
                    // No account, password, token or previous certificate exception enters inspection.
                    let inspection = try await services.inspect(endpoint.baseURL)
                    try Task.checkCancellation()
                    guard generation == requestID, attempt == submitted else { return }
                    challenge = Challenge(id: UUID(), inspection: inspection,
                        previousFingerprint: certificatePin?.sha256Fingerprint, attempt: submitted)
                    working = false
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled, generation == requestID else { return }
                    self.error = error.localizedDescription; working = false
                }
            }
        }
    }
    private static func isCertificateFailure(_ error: Error) -> Bool {
        guard let error = error as? MediaServerError else { return false }
        if case .certificate = error { return true }
        return false
    }
}

struct CertificateConfirmationView: View {
    let challenge: ServerLoginState.Challenge
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("核对此服务器证书", systemImage: "exclamationmark.shield")
                .font(.system(size: 23, weight: .semibold)).foregroundStyle(.orange)
            Text("服务器的身份未通过系统验证。只有在你能确认地址和证书来自自己的服务器时，才继续登录。此选择仅适用于 SeatSix 中的这一个服务器地址和端口。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let previous = challenge.previousFingerprint, previous != challenge.inspection.sha256Fingerprint {
                Text("证书与先前信任的证书不同。服务器可能更换了证书，也可能有连接被截获的风险，请重新核对。")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("服务器地址（含端口）", challenge.inspection.origin)
                    field("颁发给", challenge.inspection.subject)
                    field("颁发者", challenge.inspection.issuer)
                    field("有效期", "\(date(challenge.inspection.validFrom)) — \(date(challenge.inspection.validUntil))")
                    field("SHA-256 指纹（请与服务器端核对）", challenge.inspection.sha256Fingerprint, mono: true)
                    if let previous = challenge.previousFingerprint {
                        field("先前信任的 SHA-256 指纹", previous, mono: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 9))
            }.frame(maxHeight: 320)
            if let failure = challenge.inspection.trustFailureDescription {
                Text(failure).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("自签名证书或证书名称与地址不一致时，系统无法确认对方身份。请从服务器管理员提供的独立渠道核对上面的完整指纹。")
                .font(.system(size: 11)).foregroundStyle(SeatSixStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if !challenge.inspection.canApprove {
                Text("此证书已过期、尚未生效或无法安全使用。请先在服务器修复证书，再重新连接。")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack {
                Button("取消", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Spacer()
                Button("仅信任这张证书并继续", action: approve)
                    .disabled(!challenge.inspection.canApprove)
                    .buttonStyle(.bordered)
                    // Deliberately no defaultAction: Return must never grant certificate trust.
            }
        }.padding(28).frame(width: 570).background(SeatSixStyle.background)
            .preferredColorScheme(.dark).interactiveDismissDisabled().onExitCommand(perform: cancel)
    }
    private func field(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(SeatSixStyle.secondary)
            Text(value).font(.system(size: 11, design: mono ? .monospaced : .default)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func date(_ value: Date?) -> String {
        guard let value else { return "无法读取" }
        return value.formatted(date: .numeric, time: .standard)
    }
}
