// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Transkribering",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Transkribering",
            path: "Sources/Transkribering",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
