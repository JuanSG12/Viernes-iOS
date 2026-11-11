import SwiftUI
import ViernesCore

/// Misiones del agente: lo que Viernes planeó y ejecutó en varios pasos, con el resultado REAL de cada uno. Si la app se cerró a mitad,
/// la misión aparece como interrumpida y se puede reanudar (solo repite lo que no terminó).
struct MissionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Text("Cuando pides algo de varios pasos («organiza mi día», «organiza el día de mañana», «organiza mi semana»), Viernes lo divide en pasos, consulta en paralelo lo que puede y te cuenta SOLO los resultados reales; lo que falla lo dice con el motivo, no lo inventa. Las consultas no piden confirmación; cualquier acción sensible sí.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Misiones recientes") {
                if model.missionStates.isEmpty {
                    Text("Todavía no hay misiones. Prueba con «Viernes, organiza mi día en Medellín».").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.missionStates) { state in
                    NavigationLink { MissionDetailView(id: state.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.goal).foregroundStyle(Theme.textPrimary).lineLimit(2)
                            Text("\(state.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(MissionReport.label(state.status)) · \(state.steps.filter { $0.status == .done }.count) de \(state.steps.count) pasos")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("mission-row")
                }
                Button("Borrar el historial de misiones", role: .destructive) { confirmClear = true }
                    .disabled(model.missionStates.isEmpty)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Misiones del agente")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.reloadMissions() }
        .confirmationDialog("¿Borrar el historial de misiones?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar historial", role: .destructive) { model.clearMissions() }
        } message: { Text("Se borra el registro de este perfil. No se puede deshacer.") }
    }
}

struct MissionDetailView: View {
    let id: UUID
    @EnvironmentObject var model: AppModel

    private var state: MissionState? { model.missionStates.first { $0.id == id } }

    var body: some View {
        List {
            if let state = state {
                Section("Pasos y resultados") {
                    Text(MissionReport.text(state))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mission-report")
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
                if state.status == .interrupted || state.status == .cancelled {
                    Section {
                        Button("Reanudar (solo lo que no terminó)") { model.resumeMission(id) }
                            .accessibilityIdentifier("mission-resume")
                        Text("Repite únicamente los pasos que no terminaron, con los mismos permisos. El resultado queda aquí; no escribe en la conversación.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.carbon.opacity(0.5))
                }
            } else {
                Text("Esta misión ya no existe.").foregroundStyle(Theme.textSecondary)
            }
        }
        .chromeList()
        .navigationTitle("Misión")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.reloadMissions() }
    }
}
