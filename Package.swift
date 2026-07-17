// swift-tools-version:5.9
import PackageDescription

// TyKaozKit — TyKaoz's reusable business library on top of XSBridgeKit. It carries
// the JS agent runtime, the LLM providers and the tools, and absorbs the former
// standalone TyKaozHostC package as an internal C target (the XS host functions).
// Consumers (the TyKaoz app, TyKaozCli) `import TyKaozKit`.

// XS compile flags — MUST be byte-identical to XSBridgeKit's xsDefines: the
// txMachine/txChunk ABI depends on them, a mismatch is silent corruption.
let xsDefines: [CSetting] = [
  .define("XS_ARCHIVE", to: "1"),
  .define("INCLUDE_XSPLATFORM", to: "1"),
  .define("XSPLATFORM", to: "\"mac_xs.h\""),
  .define("mxDebug", to: "1"),
  .define("mxStringInfoCacheLength", to: "4"),
  .define("mxSnapshot", to: "1"),
]

// Header search paths must stay inside the package root, so we reach the XS
// headers through the `vendor/` symlinks (scripts/link.sh), which point at
// XSBridgeKit's already-linked, ABI-patched XS tree. Paths are relative to the
// C target directory (Sources/TyKaozHostC/); `../../vendor` is the package root's
// vendor dir. vendor/ is not a target, so the XS .c under it are never compiled.
let xsDirs = ["xs/sources", "xs/includes", "xs/platforms", "xs/tools"]
let headerPaths: [CSetting] =
  xsDirs.map { .headerSearchPath("../../vendor/" + $0) }
  + [.headerSearchPath("../../vendor/include")]

let package = Package(
    name: "TyKaozKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TyKaozKit", targets: ["TyKaozKit"]),
        .executable(name: "TyKaozCli", targets: ["TyKaozCli"]),
    ],
    dependencies: [
        .package(path: "../XSBridgeKit"),
    ],
    targets: [
        // The XS host functions (absorbed from the former TyKaozHostC package).
        .target(
            name: "TyKaozHostC",
            dependencies: [.product(name: "XSBridge", package: "XSBridgeKit")],
            cSettings: headerPaths + xsDefines
        ),
        // The reusable Swift business layer: agent runtime, providers, tools.
        .target(
            name: "TyKaozKit",
            dependencies: [
                .product(name: "XSBridgeKit", package: "XSBridgeKit"),
                .product(name: "XSBridge", package: "XSBridgeKit"),
                "TyKaozHostC",
            ],
            swiftSettings: [
                // Providers use bare `/.../` regex literals (matches the app's
                // SWIFT_ENABLE_BARE_SLASH_REGEX setting).
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
        // Headless runner for autonomous JS agents on top of TyKaozKit.
        .executableTarget(
            name: "TyKaozCli",
            dependencies: ["TyKaozKit"]
        ),
    ]
)
