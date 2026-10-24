// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "decant",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "decant", targets: ["decant"]),
        // Not "Decant": it would collide with "decant" on a case-insensitive disk. Scripts/build.sh
        // wraps it in Decant.app.
        .executable(name: "DecantApp", targets: ["DecantApp"]),
    ],
    targets: [
        .target(
            name: "DecantCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "decant",
            dependencies: ["DecantCore"],
            linkerSettings: [
                // Embeds the bundle identifier (uk.street365.decant) and version in the binary.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(Context.packageDirectory)/Support/Info.plist"]),
            ]
        ),
        .executableTarget(
            name: "DecantApp",
            dependencies: ["DecantCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "DecantCoreTests",
            dependencies: ["DecantCore"]
        ),
    ]
)
