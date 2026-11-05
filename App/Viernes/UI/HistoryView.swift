import SwiftUI
import ViernesCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    let dismissAll: () -> Void
    @State private var confirmDeleteAll = false

    var body: some View {
        List {
            Section {
                Text("Retención: \(model.settings.transcriptRetention.displayName). Las transcripciones se guardan cifradas en este dispositivo y puedes cambiarlo en Configuración › Privacidad.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear)
            }
            if model.history.isEmpty {
                Text(model.settings.transcriptRetention == .never ? "El historial está desactivado." : "Aún no hay conversaciones guardadas.")
                    .foregroundStyle(Theme.textSecondary).listRowBackground(Color.clear)
            }
            ForEach(model.history) { snapshot in
                NavigationLink {
                    ConversationDetailView(snapshot: snapshot, dismissAll: dismissAll)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.title).lineLimit(1)
                        Text("\(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.messages.count) mensajes")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
                .swipeActions {
                    Button(role: .destructive) { model.deleteConversation(snapshot) } label: { Label("Borrar", systemImage: "trash") }
                }
            }
        }
        .chromeList()
        .navigationTitle("Historial")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cerrar", action: dismissAll) }
            ToolbarItem(placement: .destructiveAction) {
                Button("Borrar todo", role: .destructive) { confirmDeleteAll = true }.disabled(model.history.isEmpty)
            }
        }
        .confirmationDialog("¿Borrar todo el historial?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Borrar historial", role: .destructive) { model.deleteAllHistory() }
        } message: { Text("No se puede deshacer. Los recuerdos de la pestaña Memoria no se tocan.") }
        .task { await model.reloadHistory() }
    }
}

struct ConversationDetailView: View {
    @EnvironmentObject var model: AppModel
    let snapshot: ConversationSnapshot
    let dismissAll: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(snapshot.messages) { message in
                    if message.role == .user {
                        UserBubble(text: message.text)
                    } else {
                        AssistantMessage(message: message, isLast: false)
                    }
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle(snapshot.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Continuar") { model.resume(snapshot); dismissAll() }
                Spacer()
                Button("Resumir a Memoria") { model.saveSummaryToMemory(of: snapshot) }
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) { if let note = model.busyNote { ChromePanel { Text(note) }.padding() } }
    }
}
