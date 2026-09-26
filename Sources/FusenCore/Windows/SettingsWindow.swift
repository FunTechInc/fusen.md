import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The 設定 window (⌘,): 一般 (the show/hide hot key) and Notion (the mirror).
@MainActor
final class SettingsWindowController: NSWindowController {
    private let sync: NotionSync

    init(sync: NotionSync, toggleShortcut: ToggleShortcut) {
        self.sync = sync
        let root = TabView {
            GeneralSettingsView(toggleShortcut: toggleShortcut)
                .tabItem { Label("一般", systemImage: "gearshape") }
            NotionSettingsView(sync: sync)
                .tabItem { Label("Notion", systemImage: "arrow.triangle.2.circlepath") }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "設定"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 680))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        sync.refreshTokenPresence()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The global show/hide shortcut. Recording captures the next key press in this window; the current
/// hot key is switched off meanwhile so pressing the same combination records it instead of firing.
struct GeneralSettingsView: View {
    let toggleShortcut: ToggleShortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        Form {
            Section("表示・非表示のショートカット") {
                Text("ほかのアプリを使っているときでも、このショートカットで付箋をすべて隠したり、表示したりできます。付箋が見えているときは隠し、隠れているかほかのウインドウの後ろにあるときは手前に表示します。")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(isRecording ? "キーを押してください…" : (toggleShortcut.shortcut?.displayString ?? "使わない"))
                        .font(.title3.monospaced())
                        .foregroundStyle(isRecording ? .secondary : .primary)
                    Spacer()
                    Button(isRecording ? "キャンセル" : "変更…") { isRecording ? stopRecording() : startRecording() }
                    Button("使わない") { toggleShortcut.set(nil) }
                        .disabled(isRecording || toggleShortcut.shortcut == nil)
                    if toggleShortcut.shortcut != .defaultToggle {
                        Button("標準に戻す（\(HotKeyShortcut.defaultToggle.displayString)）") { toggleShortcut.set(.defaultToggle) }
                            .disabled(isRecording)
                    }
                }
                if let error = toggleShortcut.errorMessage, !isRecording {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text(hint ?? "⌘・⌃・⌥ のどれかを含む組み合わせにしてください。Esc で取り消せます。ほかのアプリと同じ組み合わせにすると、どちらか一方しか反応しないことがあります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        hint = nil
        toggleShortcut.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let shortcut = HotKeyShortcut(event: event) {
                isRecording = false
                removeMonitor()
                toggleShortcut.set(shortcut)
            } else {
                hint = "⌘・⌃・⌥ のどれかと一緒に押してください。"
                NSSound.beep()
            }
            return nil // the key press only records, it types nothing
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        hint = nil
        removeMonitor()
        toggleShortcut.activate()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Notion settings. The token field is only ever for typing a new token: a saved token is never
/// read back into it (the placeholder just says one is saved).
struct NotionSettingsView: View {
    let sync: NotionSync
    @State private var token = ""
    @State private var pageURL = ""
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var confirmsDisconnect = false

    var body: some View {
        Form {
            Section("Notion 連携") {
                Text("メモを Notion のデータベース「fusen.md」に一方向でコピーします。見出し・リスト・チェックボックス・引用・コードなどは、アプリと同じ形で Notion に表示されます。")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("準備") {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Notion の開発者ポータルで「内部コネクション」を作り、インストールアクセストークンをコピーします。会社のワークスペースでは、作成にワークスペースオーナーの権限が必要なことがあります。自分の権限で動く個人アクセストークンも使えます（ワークスペースで許可されている場合）。")
                    step(2, "機能は「コンテンツの読み取り」「コンテンツの挿入」「コンテンツの更新」を有効にします。")
                    step(3, "メモを置きたいページを Notion で開き、右上の ••• > 接続 から、作ったコネクションを追加します（個人アクセストークンの場合は不要）。")
                    step(4, "下にトークンとそのページの URL を入れて「接続」を押すと、ページの中にデータベースができ、メモが同期されます。")
                    Link("Notion の開発者ポータルを開く", destination: URL(string: "https://www.notion.so/developers")!)
                }
            }

            Section("接続") {
                SecureField("トークン", text: $token,
                            prompt: Text(sync.hasToken ? "保存済み（変えるときだけ入力）" : "トークンを貼り付け"))
                TextField("親ページの URL", text: $pageURL, prompt: Text("https://www.notion.so/…"))
                HStack {
                    Button("接続", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isConnecting || pageURL.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (token.isEmpty && !sync.hasToken))
                    if isConnecting { ProgressView().controlSize(.small) }
                }
                if let connectError {
                    Text(connectError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("同期") {
                LabeledContent("状態", value: statusText)
                if let workspace = sync.workspaceName {
                    LabeledContent("ワークスペース", value: workspace)
                }
                if let url = sync.databaseURL.flatMap(URL.init(string:)) {
                    Link("Notion でデータベースを開く", destination: url)
                }
                if let error = sync.lastError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("今すぐ同期") { Task { await sync.syncNow() } }
                        .disabled(!sync.isEnabled || sync.isSyncing)
                    Button(sync.isEnabled ? "同期を停止" : "同期を再開") {
                        if sync.isEnabled { sync.pause() } else { sync.resume() }
                    }
                    .disabled(!sync.isConfigured || (!sync.isEnabled && !sync.hasToken))
                    Spacer()
                    Button("接続を解除…") { confirmsDisconnect = true }
                        .disabled(!sync.hasToken && !sync.isEnabled)
                }
            }

            Section("注意") {
                VStack(alignment: .leading, spacing: 6) {
                    note("同期はこの Mac から Notion への一方向です。Notion 側で編集した内容は、そのメモを次に変更したときに上書きされます。元に戻すときは、このアプリの「メモの履歴」を使ってください。")
                    note("閉じたメモは Notion で「状態: 削除済み」になります。ページは削除されません。")
                    note("Notion でメモのページにサブページやデータベースを追加すると、本文の置き換えで消えてしまうため、そのメモの本文は同期されなくなります。")
                    note("一度に大部分を消したときは、誤操作に備えて 15 分待ってから反映します。")
                    note("トークンはこの Mac の Keychain にだけ保存され、この画面には表示されません。")
                    note("会社のワークスペースにメモを保存してよいかは、社内の規程に従ってご自身で確認してください。")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 680)
        .onAppear { if pageURL.isEmpty { pageURL = sync.parentPageURL ?? "" } }
        .confirmationDialog("Notion との接続を解除しますか？", isPresented: $confirmsDisconnect) {
            Button("接続を解除", role: .destructive) { sync.disconnect() }
        } message: {
            Text("トークンを Keychain から削除し、同期を止めます。Notion のページはそのまま残ります。")
        }
    }

    private var statusText: String {
        guard sync.isConfigured else { return "未接続" }
        guard sync.isEnabled else { return "停止中" }
        var parts: [String] = []
        if sync.isSyncing {
            parts.append("同期中…")
        } else if let date = sync.lastSyncAt {
            parts.append("最終同期 " + date.formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append("まだ同期していません")
        }
        if sync.pendingCount > 0 { parts.append("未送信 \(sync.pendingCount) 件") }
        if sync.heldCount > 0 { parts.append("大きな削除を保留中 \(sync.heldCount) 件") }
        return parts.joined(separator: "・")
    }

    private func connect() {
        isConnecting = true
        connectError = nil
        Task {
            defer { isConnecting = false }
            do {
                try await sync.connect(token: token, parentPageURL: pageURL)
                token = "" // never kept in the view once saved
            } catch {
                connectError = (error as? NotionSync.SyncError)?.message ?? error.localizedDescription
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text("・" + text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
