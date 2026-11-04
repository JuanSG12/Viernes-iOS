// swift-tools-version: 5.9
//
// ViernesCore: lógica portable de Viernes (solo Foundation, sin frameworks de UI ni de audio).
// Se compila y se prueba con `swift test` en macOS (y, al ser Foundation puro, en Linux/Windows).
// La app iOS (carpeta App/) consume este paquete como dependencia local desde project.yml.
import PackageDescription

let package = Package(
    name: "ViernesCore",
    platforms: [.iOS("18.0"), .macOS(.v14)],     // .v18 exige tools-version 6.0; la cadena funciona en 5.9
    products: [
        .library(name: "ViernesCore", targets: ["ViernesCore"])
    ],
    targets: [
        .target(name: "ViernesCore", path: "Sources/ViernesCore"),
        .testTarget(
            name: "ViernesCoreTests",
            dependencies: ["ViernesCore"],
            path: "Tests/ViernesCoreTests"
        )
    ]
)
