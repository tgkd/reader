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
            name: "CMeCab",
            exclude: [
                "src/make.bat",
                "src/Makefile.am",
                "src/Makefile.in",
                "src/Makefile.msvc.in",
                "src/mecab.cpp",
                "src/mecab-cost-train.cpp",
                "src/mecab-dict-gen.cpp",
                "src/mecab-dict-index.cpp",
                "src/mecab-system-eval.cpp",
                "src/mecab-test-gen.cpp",
            ],
            sources: ["src"],
            resources: [.copy("BSD"), .copy("COPYING"), .copy("AUTHORS")],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .define("MECAB_USE_UTF8_ONLY"),
                .headerSearchPath("include"),
            ],
            cxxSettings: [.define("HAVE_ICONV")],
            linkerSettings: [.linkedLibrary("iconv")]
        ),
        .target(
            name: "ReaderCore",
            dependencies: [
                "CMeCab",
                .product(name: "IPADic", package: "Mecab-Swift"),
            ]
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: [
                "ReaderCore",
                "CMeCab",
                .product(name: "IPADic", package: "Mecab-Swift"),
            ],
            exclude: ["fixtures", "corpus"]
        ),
    ]
)
