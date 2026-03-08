// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Claw",
  platforms: [
    .iOS("17.0")
  ],
  products: [
    .executable(
      name: "Claw",
      targets: ["Claw"]
    )
  ],
  targets: [
    .executableTarget(
      name: "Claw",
      path: "Sources"
    )
  ]
)
