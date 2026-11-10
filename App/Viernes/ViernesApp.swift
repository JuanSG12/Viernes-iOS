import SwiftUI
import SwiftData

@main
struct ViernesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Dueño de los perfiles: crea el modelo del perfil activo (con SUS almacenes cifrados, SU clave y SUS ajustes) y lo sustituye
    /// al cambiar de perfil. Las pruebas de UI usan almacenes en RAM para no tocar datos reales.
    @StateObject private var host: ProfileHost

    init() {
        let isUITest = CommandLine.arguments.contains("--uitest")
        _host = StateObject(wrappedValue: ProfileHost(inMemory: isUITest))
    }

    var body: some Scene {
        WindowGroup {
            ProfileRoot()
                .environmentObject(host)
                .preferredColorScheme(.dark)
                .onOpenURL { host.model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in host.model.scenePhaseChanged(phase) }
        }
    }
}

/// Muestra la app del perfil activo. Al cambiar de perfil la identidad cambia y SwiftUI descarta todo el estado de pantalla anterior.
struct ProfileRoot: View {
    @EnvironmentObject var host: ProfileHost

    var body: some View {
        if host.isLocked {
            LockedProfileView()
        } else {
            let model = host.model
            RootView(launchError: host.launchError)
                .environmentObject(model)
                .environmentObject(model.confirmation)
                .environmentObject(model.mailDrafts)
                .id(model.profileEntry.id)
                .task(id: model.profileEntry.id) { await model.bootstrap() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    let launchError: String?

    var body: some View {
        if model.settings.onboardingCompleted {
            MainView()
                .onAppear { if let launchError = launchError { model.showBanner(launchError) } }
        } else {
            OnboardingView { model.settings.onboardingCompleted = true }
        }
    }
}
