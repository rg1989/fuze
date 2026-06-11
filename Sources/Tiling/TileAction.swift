/// Every tiling operation Fuse can perform. String raw values exist solely
/// for readable log lines — never persist or switch on the raw value.
enum TileAction: String, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximize
    case center
    case nextDisplay
}
