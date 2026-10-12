// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ccode",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CCodeCore", targets: ["CCodeCore"]), .executable(name: "ccode", targets: ["CCode"]), .executable(name: "ccode-probe", targets: ["CCodeProbe"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "CCodeCore"),
        .executableTarget(name: "CCode", dependencies: ["CCodeCore", .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.copy("Resources/Inter-Regular.otf"), .copy("Resources/Inter-LICENSE.txt")]),
        .executableTarget(name: "CCodeProbe", dependencies: ["CCodeCore"]),
        .testTarget(name: "CCodeCoreTests", dependencies: ["CCodeCore", "CCode", .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.copy("Fixtures")])
    ]
)
