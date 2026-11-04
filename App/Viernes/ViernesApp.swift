import SwiftUI
import SwiftData

@main
struct ViernesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: AppModel
    private let launchError: String?

    init() {
        let container: ModelContainer
        var failureMessage: String?
        // Las pruebas de UI usan un almacén en RAM para no tocar datos reales.
        let isUITest = CommandLine.arguments.contains("--uitest")
        do {
            container = try ViernesStore.makeContainer(inMemory: isUITest)
        } catch let storeError {
            // Si el almacén en disco falla, se usa uno en RAM y se avisa: nada se guarda hasta resolverlo.
            container = try! ViernesStore.makeContainer(inMemory: true)
            failureMessage = "No pude abrir el almacén de datos (\(storeError.localizedDescription)). Esta sesión no se guardará."
        }
        launchError = failureMessage
        _model = StateObject(wrappedValue: AppModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView(launchError: launchError)
                .environmentObject(model)
                .environmentObject(model.confirmation)
                .preferredColorScheme(.dark)
                .task { await model.bootstrap() }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
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
