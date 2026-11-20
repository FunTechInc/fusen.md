import SwiftUI

/// 設定 > Markdown: the Markdown this app understands (Notion's shortcuts), each with what it becomes.
struct MarkdownSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("付箋は Markdown で書きます。記号は打った時点で書式に変わり、見えなくなります（Notion と同じ）。記号を表示して直したいときは「メモ > Markdown記号をすべて表示」（⇧⌘M）を使います。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("記号は英数入力で打ってください。日本語入力のままだと「ー」や「「」」になり、書式になりません。下の表の ␣ はスペースです。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("行の先頭で") {
                row("#␣", Text("見出し 1").font(.title.weight(.semibold)))
                row("##␣", Text("見出し 2").font(.title2.weight(.semibold)))
                row("###␣", Text("見出し 3").font(.title3.weight(.semibold)))
                row("####␣", Text("見出し 4").font(.headline))
                row("-␣", Text("•  箇条書き"), note: "*␣ や +␣ でも")
                row("1.␣", Text("1.  番号付きリスト"))
                row("[]", Label("チェックボックス", systemImage: "square"), note: "-␣[␣]␣ でも。クリックでチェック")
                row("[>]", signal(.waiting, "待機のタスク"), note: "-␣[>]␣ でも。次にやるもの")
                row("[/]", signal(.doing, "進行中のタスク"), note: "-␣[/]␣ でも。輪が回る")
                row(">␣", Text("引用").padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary).frame(width: 3) })
                row("---", Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 120, height: 1),
                    note: "区切り線。「書式」メニューからも")
                row("```", Text("コードブロック").font(.body.monospaced()), note: "次の ``` の行までがコード")
                row("/", Text("カード・信号などを選ぶメニュー"), note: "スペースの後でも。日本語入力では ；")
            }

            Section("カード") {
                Text("カードは、色と名前の付いた枠です。「書式 > カードを挿入」か / メニューで作り、中には普通の Markdown を書きます。")
                    .fixedSize(horizontal: false, vertical: true)
                row(":::card␣色␣名前", Text("カードの始まり"), note: ":::  の行までがカード")
                row("枠をドラッグ", Text("並べ替え。別のカードの左右の端に落とすと横に並ぶ"), note: "Esc で中止")
                row("•••", Text("色を変える・カードを解除・削除"), note: "枠の右クリックでも")
                row("Return", Text("名前から中身へ。中身の最後の空行で押すとカードの下へ"))
            }

            Section("文中で") {
                row("**太字**", Text("太字").bold(), note: "⌘B")
                row("*斜体*", slanted(Text("斜体")), note: "⌘I")
                row("***太字の斜体***", slanted(Text("太字の斜体").bold()))
                row("~~取り消し線~~", Text("取り消し線").strikethrough(), note: "⇧⌘S")
                row("`コード`", Text("コード").font(.body.monospaced())
                    .foregroundStyle(Color(red: 235 / 255, green: 87 / 255, blue: 87 / 255)), note: "⌘E")
                row("[リンク](URL)", Text("リンク").underline(), note: "⌘K。⌘クリックで開く")
                row("https://…", Text("https://…").underline(), note: "URL はそのままリンクに")
                row("\\*", Text("*"), note: "\\ を付けた記号は書式にならない")
            }

            Section("書式のショートカット") {
                Text("文字を選んで ⌘B・⌘I・⇧⌘S・⌘E を押すと書式が付き、選んだ文字がすべてその書式なら外れます。何も選ばずに押すと、次に打つ文字にその書式が付きます。")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("タスクの状態") {
                Text("タスクには、未着手・待機・進行中・完了の 4 つの状態があります。チェックボックスや信号をクリックすると、一歩進みます。")
                    .fixedSize(horizontal: false, vertical: true)
                row("クリック", Text("待機 → 進行中 → 完了。未着手はそのまま完了に"), note: "⌘Return")
                row("⌥クリック", Text("待機にする。待機のタスクは未着手に戻す"), note: "⌥⌘Return")
                row("右クリック", Text("4 つの状態から選ぶ"), note: "「書式 > タスクの状態」でも")
            }

            Section("編集") {
                row("Return", Text("リストやチェックボックスの次の項目。空の項目で押すと終わり"))
                row("Tab・⇧Tab", Text("リストを一段深く・浅く"))
                row("行頭で ⌫", Text("見出しやリストを普通の文章に戻す"))
            }
        }
        .formStyle(.grouped)
    }

    /// A signal as the notes draw it, with its name.
    private func signal(_ state: TaskState, _ title: String) -> some View {
        Label { Text(title) } icon: { Image(nsImage: TaskSignalIcon.image(state, theme: MarkdownTheme(), ink: .labelColor)) }
    }

    /// Slanted as the notes show italic text: Japanese fonts have no italic face.
    private func slanted(_ text: some View) -> some View {
        text.transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: 3, ty: 0))
    }

    /// A row: what to type, and what it becomes (with a note, such as its shortcut).
    private func row(_ markdown: String, _ result: some View, note: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(markdown)
                .font(.callout.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                .frame(width: 150, alignment: .leading)
            result
            Spacer(minLength: 8)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }
}
