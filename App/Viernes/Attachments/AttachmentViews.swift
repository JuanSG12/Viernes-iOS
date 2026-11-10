import SwiftUI
import QuickLook
import ViernesCore

private let failureColor = Color(red: 1.0, green: 0.38, blue: 0.34)

/// Fila de adjuntos sobre el redactor: cada uno con su estado REAL (leyendo, listo, con aviso o con error) y un botón para quitarlo.
struct AttachmentStrip: View {
    @ObservedObject var center: AttachmentCenter
    var onSelect: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(center.drafts.enumerated()), id: \.element.id) { index, draft in
                    DraftChip(draft: draft, onSelect: { onSelect(draft.id) }, onRemove: { center.remove(draft.id) })
                        .accessibilityIdentifier("attachment-chip-\(index)")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 60)
        .accessibilityIdentifier("attachment-strip")
    }
}

private struct DraftChip: View {
    let draft: DraftAttachment
    let onSelect: () -> Void
    let onRemove: () -> Void

    private var tint: Color {
        if draft.failureText != nil { return failureColor }
        if draft.state == .processing { return Theme.chrome }
        return draft.notes.isEmpty ? Theme.accent : Theme.amber
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name)
                            .font(Theme.body(12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).frame(maxWidth: 118, alignment: .leading)
                        status
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Adjunto \(draft.name), \(statusText)")
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quitar \(draft.name)")
            .accessibilityIdentifier("attachment-remove")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .chromeSurface(tint: tint, radius: 14)
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = draft.thumbnail {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: draft.kind?.symbolName ?? "doc")
                .font(.system(size: 18, weight: .light)).foregroundStyle(Theme.silver)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.carbon))
        }
    }

    @ViewBuilder private var status: some View {
        switch draft.state {
        case .processing:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                Text("Leyendo…").font(Theme.mono(9)).foregroundStyle(Theme.textSecondary)
            }
        case .ready:
            HStack(spacing: 4) {
                if !draft.notes.isEmpty { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.amber) }
                Text(statusText).font(Theme.mono(9)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 9)).foregroundStyle(failureColor)
                Text("No se pudo leer").font(Theme.mono(9)).foregroundStyle(failureColor)
            }
        }
    }

    private var statusText: String {
        switch draft.state {
        case .processing: return "leyendo"
        case .failed: return "no se pudo leer"
        case .ready:
            let kind = draft.kind?.displayName ?? "Archivo"
            let size = ByteCountFormatter.string(fromByteCount: Int64(draft.byteCount), countStyle: .file)
            return draft.notes.isEmpty ? "\(kind) · \(size)" : "\(kind) · \(size) · con avisos"
        }
    }
}

/// Detalle de un adjunto: lo que se leyó (distinto de lo que se interpretará), avisos, errores y vista previa del archivo.
struct AttachmentDetailSheet: View {
    @ObservedObject var center: AttachmentCenter
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var quickLookURL: URL?

    private var draft: DraftAttachment? { center.drafts.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            Group {
                if let draft = draft { content(draft) } else { Text("Este adjunto ya no está.").foregroundStyle(Theme.textSecondary) }
            }
            .navigationTitle("Adjunto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Quitar", role: .destructive) { center.remove(id); dismiss() }.accessibilityIdentifier("attachment-detail-remove")
                }
            }
            .quickLookPreview($quickLookURL)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.ink)
    }

    @ViewBuilder private func content(_ draft: DraftAttachment) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.name).font(.system(size: 20, weight: .light)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                Text(summaryLine(draft)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)

                if let error = draft.failureText {
                    ChromePanel(tint: failureColor) {
                        Text(error).font(Theme.body(14)).foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("attachment-error")
                }
                if !draft.notes.isEmpty {
                    ChromePanel(tint: Theme.amber) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(draft.notes, id: \.self) { note in
                                Text("• " + note).font(Theme.body(13)).foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                if draft.kind == .image, let url = draft.previewURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("Esto es exactamente lo que se enviaría a un modelo con visión: la imagen ya reducida.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                if let document = draft.document {
                    Theme.label("Lo que leí (texto extraído, sin interpretar)")
                    Text(String(document.fullText.prefix(1_800)) + (document.characterCount > 1_800 ? "\n[…]" : ""))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .accessibilityIdentifier("attachment-extracted-text")
                }
                if draft.kind != .image, let url = draft.previewURL {
                    Button("Abrir vista rápida") { quickLookURL = url }
                        .buttonStyle(ChromeButtonStyle(tint: Theme.accent))
                }
            }
            .padding(20)
        }
    }

    private func summaryLine(_ draft: DraftAttachment) -> String {
        var parts: [String] = []
        if let kind = draft.kind { parts.append(kind.displayName) }
        if draft.byteCount > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(draft.byteCount), countStyle: .file)) }
        if let info = draft.info { parts.append(info) }
        switch draft.state {
        case .processing: parts.append("leyendo…")
        case .ready: parts.append("listo para enviar")
        case .failed: parts.append("no se pudo leer")
        }
        return parts.joined(separator: " · ")
    }
}

/// Chip de un adjunto ya enviado, dentro de la burbuja del usuario.
struct SentAttachmentChip: View {
    let ref: AttachmentRef
    var onOpen: (() -> Void)?

    var body: some View {
        Button { onOpen?() } label: {
            HStack(spacing: 5) {
                Image(systemName: ref.kind.symbolName).font(.system(size: 11)).foregroundStyle(Theme.silver)
                Text(ref.name).font(Theme.body(11, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1).frame(maxWidth: 150)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .chromeSurface(tint: Theme.chrome, radius: 10)
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .accessibilityLabel("Adjunto enviado: \(ref.name)")
        .accessibilityIdentifier("sent-attachment")
    }
}
