import SwiftUI
import MessageUI
import ViernesCore

/// Compositor de correo de iOS (MFMailComposeViewController) dentro de la app. Devuelve el resultado REAL: enviado, guardado,
/// cancelado o fallido. Solo existe si el iPhone tiene una cuenta en la app Correo (`MFMailComposeViewController.canSendMail()`).
struct MailComposerView: UIViewControllerRepresentable {
    let content: MailDraftContent
    let onFinish: (MailDraftResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        let to = SpokenText.cleanEmailAddress(content.to)
        if !to.isEmpty { controller.setToRecipients([to]) }
        controller.setSubject(content.subject)
        controller.setMessageBody(content.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MailDraftResult) -> Void
        init(onFinish: @escaping (MailDraftResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            switch result {
            case .sent: onFinish(.composerSent)
            case .saved: onFinish(.composerSaved)
            case .cancelled: onFinish(.composerCancelled)
            case .failed: onFinish(.composerFailed(error?.localizedDescription ?? "error desconocido"))
            @unknown default: onFinish(.composerCancelled)
            }
        }
    }
}

/// Vista previa del correo ANTES de abrir Correo: el usuario ve (y puede editar) destinatario, asunto y texto.
/// Nada se envía desde aquí: «Abrir en Correo» abre el compositor y es el usuario quien pulsa Enviar. Si Correo no se puede abrir,
/// el borrador se conserva en esta hoja para copiarlo.
struct MailDraftSheet: View {
    let draft: MailDraft
    @EnvironmentObject var center: MailDraftCenter

    @State private var to: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var composer: MailDraft?
    @State private var copiedNow = false

    init(draft: MailDraft) {
        self.draft = draft
        _to = State(initialValue: draft.content.to)
        _subject = State(initialValue: draft.content.subject)
        _bodyText = State(initialValue: draft.content.body)
    }

    private var current: MailDraftContent { MailDraftContent(to: to, subject: subject, body: bodyText) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Theme.label("Borrador de correo")
                Text("Revisa el mensaje. Viernes no envía nada: se abre Correo y tú pulsas Enviar.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)

                field("Para", text: $to, placeholder: "Sin destinatario: lo añades en Correo", id: "mail-to", keyboard: .emailAddress)
                field("Asunto", text: $subject, placeholder: "Sin asunto", id: "mail-subject", keyboard: .default)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mensaje").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $bodyText)
                        .font(Theme.body(15))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 170)
                        .padding(8)
                        .chromeSurface(tint: Theme.accent, radius: 14)
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("mail-body")
                }

                if let problem = center.problem ?? current.recipientProblem {
                    Text(problem).font(Theme.body(13)).foregroundStyle(Theme.amber)
                        .accessibilityIdentifier("mail-problem")
                }

                VStack(spacing: 10) {
                    Button { openInMail() } label: { Label("Abrir en Correo", systemImage: "envelope") }
                        .buttonStyle(ChromeButtonStyle(tint: Theme.accent))
                        .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current.recipientProblem != nil)
                        .accessibilityIdentifier("mail-open")
                    if MFMailComposeViewController.canSendMail() {
                        Button { openWithMailto() } label: { Label("Usar otra app de correo", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(ChromeButtonStyle(tint: Theme.chrome))
                            .disabled(current.recipientProblem != nil)
                            .accessibilityIdentifier("mail-open-other")
                    }
                    HStack(spacing: 10) {
                        Button { copy() } label: { Label(copiedNow ? "Copiado" : "Copiar", systemImage: copiedNow ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(ChromeButtonStyle(tint: Theme.chrome))
                            .accessibilityIdentifier("mail-copy")
                        Button(center.copied ? "Listo" : "Descartar") { center.close() }
                            .buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                            .accessibilityIdentifier("mail-close")
                    }
                }
            }
            .padding(24)
        }
        .sheet(item: $composer) { item in
            MailComposerView(content: item.content) { result in
                composer = nil
                center.finish(result)
            }
            .ignoresSafeArea()
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, id: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? TextInputAutocapitalization.never : TextInputAutocapitalization.sentences)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .font(Theme.body(15))
                .padding(.horizontal, 14).padding(.vertical, 11)
                .chromeSurface(tint: Theme.accent, radius: 14)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier(id)
        }
    }

    /// Compositor de iOS si hay una cuenta en la app Correo; si no, `mailto:` (abre la app de correo predeterminada).
    private func openInMail() {
        if MFMailComposeViewController.canSendMail() {
            composer = MailDraft(content: normalized())
        } else {
            openWithMailto()
        }
    }

    private func openWithMailto() {
        let content = normalized()
        guard let url = content.mailtoURL else {
            center.problem = "No pude construir el enlace del correo. Copia el borrador y pégalo en tu app de correo."
            return
        }
        UIApplication.shared.open(url) { opened in
            Task { @MainActor in
                if opened {
                    center.finish(.openedExternal)
                } else {
                    center.problem = "No pude abrir una app de correo en este iPhone. Tu borrador sigue aquí: cópialo y pégalo donde quieras."
                }
            }
        }
    }

    private func normalized() -> MailDraftContent {
        MailDraftContent(to: SpokenText.cleanEmailAddress(to), subject: subject.trimmingCharacters(in: .whitespacesAndNewlines), body: bodyText)
    }

    private func copy() {
        UIPasteboard.general.string = normalized().plainText
        center.markCopied()
        copiedNow = true
    }
}
