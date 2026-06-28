// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReaderCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/shinjukunian/Mecab-Swift.git", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "ReaderCore",
            dependencies: [
                .product(name: "Mecab-Swift", package: "Mecab-Swift"),
                .product(name: "IPADic", package: "Mecab-Swift"),
            ]
        ),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
    ]
)
