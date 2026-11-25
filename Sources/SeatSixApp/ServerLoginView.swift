import SwiftUI
import SeatSixCore

struct ServerLoginView: View {
    @ObservedObject var model: ApplicationModel
    let existing: ServerConnection?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loginState: ServerLoginState
    @State private var name: String
    @State private var selectedLibraries: Set<String> = []
    @State private var showPassword = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, host, port, path, username, password }

    init(model: ApplicationModel, existing: ServerConnection?, state: ServerLoginState? = nil) {
        self.model = model; self.existing = existing
        _loginState = StateObject(wrappedValue: state ?? ServerLoginState(deviceID: model.deviceID, existing: existing))
        _name = State(initialValue: existing?.name ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.04))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if loginState.authenticated == nil { loginForm } else { libraryForm }
                }.padding(24)
            }
            if let error = loginState.error {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(height: 64)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24).padding(.bottom, 12)
                .accessibilityIdentifier("server-login-error")
            }
            Divider().overlay(Color.white.opacity(0.04))
            footer
        }
        .frame(width: 560, height: 630)
        .background(SeatSixStyle.background)
        .preferredColorScheme(.dark).tint(SeatSixStyle.accent)
        .onAppear { focusedField = existing == nil ? .host : .password }
        .onChange(of: focusedField) { previous, current in
            if previous == .host, current != .host { loginState.addressForm.updateHost(loginState.addressForm.host) }
        }
        .onChange(of: loginState.working) { _, working in if working { showPassword = false } }
        .onChange(of: loginState.authenticated != nil) { _, authenticated in
            guard authenticated else { return }
            showPassword = false
            let available = Set(loginState.libraries.map(\.id))
            selectedLibraries = existing.map { available.intersection($0.libraryIDs) } ?? available
        }
        .sheet(item: Binding(get: { loginState.challenge }, set: { if $0 == nil, loginState.challenge != nil { loginState.cancelTrust() } })) { challenge in
            CertificateConfirmationView(challenge: challenge,
                approve: { loginState.approve(challenge.id) }, cancel: { loginState.cancelTrust() })
        }
        .interactiveDismissDisabled(loginState.working || loginState.challenge != nil)
        .onDisappear { showPassword = false; loginState.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: loginState.authenticated == nil ? "externaldrive.connected.to.line.below" : "rectangle.stack")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(SeatSixStyle.accent)
                .frame(width: 42, height: 42)
                .background(SeatSixStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(loginState.authenticated == nil ? (existing == nil ? "添加服务器" : "重新连接服务器") : "选择媒体库")
                    .font(.system(size: 20, weight: .semibold))
                Text(loginState.authenticated == nil ? "连接你的电影与剧集" : "选择要在 SeatSix 中浏览的内容")
                    .font(.system(size: 11)).foregroundStyle(SeatSixStyle.secondary)
            }
            Spacer()
            Text(loginState.authenticated == nil ? "1 / 2" : "2 / 2")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(SeatSixStyle.secondary)
            Button(action: cancel) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain).accessibilityLabel("关闭添加服务器").help("取消并关闭")
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("服务器类型", selection: $loginState.source) {
                    ForEach(ServerLoginSource.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("server-source")
                HStack(spacing: 7) {
                    Image(systemName: "externaldrive").foregroundStyle(SeatSixStyle.secondary)
                    Text("绿联云影视").font(.system(size: 11, weight: .medium))
                    Text("通过 Emby 兼容接口连接").font(.system(size: 10)).foregroundStyle(SeatSixStyle.secondary)
                    Spacer(minLength: 0)
                    Button("使用配置") { loginState.applyUGREENPreset(); focusedField = .host }
                        .font(.system(size: 11)).buttonStyle(.borderless)
                        .accessibilityLabel("使用绿联云影视配置").accessibilityIdentifier("server-ugreen-preset")
                }
            }
            field("名称", hint: "可选") {
                TextField(loginState.compatibilityMode ? "留空使用服务器地址" : "留空自动获取服务器名称", text: $name)
                    .focused($focusedField, equals: .name).accessibilityLabel("连接名称")
                    .accessibilityIdentifier("server-name")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionTitle("连接信息", symbol: "network")
                    Spacer()
                    Toggle("HTTPS", isOn: $loginState.addressForm.useHTTPS)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                        .accessibilityIdentifier("server-https")
                }
                field("服务器地址") {
                    TextField("IP、域名或完整服务器地址", text: Binding(
                        get: { loginState.addressForm.host },
                        set: { loginState.addressForm.editHost($0) }))
                        .focused($focusedField, equals: .host).textContentType(.URL)
                        .accessibilityLabel("服务器地址").accessibilityIdentifier("server-host")
                        .onSubmit { loginState.addressForm.updateHost(loginState.addressForm.host); focusedField = .username }
                }
                HStack(alignment: .top, spacing: 14) {
                    field("路径", hint: "可选") {
                        TextField("例如 /emby 或 /jellyfin", text: $loginState.addressForm.path)
                            .focused($focusedField, equals: .path).accessibilityLabel("服务器路径")
                            .accessibilityIdentifier("server-path")
                    }
                    field("端口", hint: "可选") {
                        TextField(loginState.addressForm.useHTTPS ? "443" : "80", text: $loginState.addressForm.port)
                            .focused($focusedField, equals: .port).accessibilityLabel("端口号")
                            .accessibilityIdentifier("server-port")
                    }.frame(width: 126)
                }
                if let message = loginState.validationMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("server-address-validation")
                } else if let preview = loginState.addressForm.preview {
                    Text(preview).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SeatSixStyle.secondary).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle).accessibilityIdentifier("server-address-preview")
                }
                if !loginState.addressForm.useHTTPS {
                    Text("HTTP 仅限可信局域网，账户和媒体将以明文传输。")
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if loginState.compatibilityMode {
                    Text("兼容模式仅支持原片直放。请在服务器开启 Emby 兼容服务，并核对端口与路径。")
                        .font(.system(size: 11)).foregroundStyle(SeatSixStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("服务器账户", symbol: "person.crop.circle")
                HStack(alignment: .top, spacing: 14) {
                    field("用户名", hint: "必填") {
                        TextField("服务器账户", text: $loginState.username).textContentType(.username)
                            .focused($focusedField, equals: .username).accessibilityLabel("用户名")
                            .accessibilityIdentifier("server-username")
                    }
                    field("密码", hint: "可留空") {
                        HStack(spacing: 8) {
                            Group {
                                if showPassword { TextField("密码", text: $loginState.password) }
                                else { SecureField("密码", text: $loginState.password) }
                            }.textContentType(.password).focused($focusedField, equals: .password)
                                .accessibilityLabel("密码").accessibilityIdentifier("server-password")
                            Button {
                                focusedField = nil
                                showPassword.toggle()
                                // The secure and plain controls are different native fields.
                                // Restore focus after SwiftUI has replaced the old control.
                                DispatchQueue.main.async { focusedField = .password }
                            } label: { Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 22, height: 20) }
                                .buttonStyle(.plain).foregroundStyle(SeatSixStyle.secondary)
                                .help(showPassword ? "隐藏密码" : "显示密码")
                                .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
                                .accessibilityIdentifier("server-password-visibility")
                        }
                    }
                }
            }
        }.disabled(loginState.working)
    }

    private var libraryForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("已连接 · \(loginState.authenticated?.connection.name ?? "")", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(SeatSixStyle.accent)
            Text("账户：\(loginState.authenticated?.connection.username ?? "")")
                .font(.system(size: 12)).foregroundStyle(SeatSixStyle.secondary)
            if loginState.libraries.isEmpty {
                Text("服务器暂无可用的视频媒体库。可以先保存连接，添加媒体后再重新选择。")
                    .font(.system(size: 12)).foregroundStyle(SeatSixStyle.secondary).padding(.vertical, 22)
            } else {
                HStack {
                    Text("已选择 \(selectedLibraries.count) / \(loginState.libraries.count) 个媒体库")
                        .font(.system(size: 11)).foregroundStyle(SeatSixStyle.secondary)
                    Spacer()
                    Button(selectedLibraries.count == loginState.libraries.count ? "取消全选" : "全选") {
                        selectedLibraries = selectedLibraries.count == loginState.libraries.count ? [] : Set(loginState.libraries.map(\.id))
                    }.buttonStyle(.borderless).font(.system(size: 11))
                }
                ForEach(loginState.libraries) { library in
                    Toggle(isOn: Binding(get: { selectedLibraries.contains(library.id) }, set: {
                        if $0 { selectedLibraries.insert(library.id) } else { selectedLibraries.remove(library.id) }
                    })) {
                        Label(library.name, systemImage: library.collectionType == "tvshows" ? "tv" : "film")
                            .font(.system(size: 13))
                    }.toggleStyle(.checkbox).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if loginState.authenticated != nil {
                Button("返回修改") { loginState.back(); selectedLibraries = []; focusedField = .password }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("连接仅保存在此 Mac", systemImage: "lock")
                    Text("云端同步暂未支持").foregroundStyle(SeatSixStyle.secondary)
                }.font(.system(size: 10)).foregroundStyle(SeatSixStyle.secondary)
            }
            Spacer(minLength: 0)
            if loginState.working { ProgressView().controlSize(.small).accessibilityLabel("正在连接") }
            Button("取消", action: cancel).keyboardShortcut(.cancelAction)
            Button(loginState.authenticated == nil ? (loginState.working ? "正在连接…" : "连接服务器") : "添加媒体库") {
                if loginState.authenticated == nil { loginState.login() } else { save() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(loginState.authenticated == nil ? !loginState.canSubmit : loginState.working)
            .keyboardShortcut(.defaultAction).accessibilityIdentifier("server-submit")
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(SeatSixStyle.secondary)
    }

    private func field<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(Color.white.opacity(0.82))
                if let hint { Text(hint).foregroundStyle(SeatSixStyle.secondary) }
            }.font(.system(size: 11))
            content().textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 11).frame(height: 36)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.075), lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard let authenticated = loginState.authenticated else { return }
        do {
            try model.add(authenticated, libraryIDs: loginState.libraries.map(\.id).filter { selectedLibraries.contains($0) },
                          name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch { loginState.error = error.localizedDescription }
    }
    private func cancel() { showPassword = false; loginState.cancel(); dismiss() }
}
