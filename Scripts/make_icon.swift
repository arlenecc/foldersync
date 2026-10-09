// swift Scripts/make_icon.swift <输出1024px PNG路径>
// 用 CoreGraphics 绘制 FolderSync 应用图标：
// 蓝紫渐变圆角底板 + 双文件夹（主/副）+ 同步箭头，符合 macOS Big Sur 风格（1024 画布留边）。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// swift JIT 解释模式下驱动参数混杂，用户参数位于 "--" 分隔符之后；编译运行时无 "--"，直接跳过程序名
let allArgs = CommandLine.arguments
let userArgs: ArraySlice<String>
if let sep = allArgs.firstIndex(of: "--") {
    userArgs = allArgs[(sep + 1)...]
} else {
    userArgs = allArgs.dropFirst()
}
let outPath = userArgs.first ?? "build/icon/FolderSync_1024.png"

let size = 1024
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let S = CGFloat(size)

// MARK: - 背景圆角矩形（Big Sur 风格：824/1024，四周留边）
let margin = CGFloat(100)
let bgRect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 186, cornerHeight: 186, transform: nil))
ctx.clip()

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bgGradient = CGGradient(
    colorsSpace: srgb,
    colors: [
        CGColor(srgbRed: 0.29, green: 0.49, blue: 0.94, alpha: 1),
        CGColor(srgbRed: 0.54, green: 0.36, blue: 0.96, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0),
    options: []
)

// 顶部高光（作用于底板区域内）
let gloss = CGGradient(
    colorsSpace: srgb,
    colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gloss,
    start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S * 0.45),
    options: []
)

// MARK: - 文件夹绘制
func drawFolder(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                topColor: CGColor, bottomColor: CGColor) {
    let corner = CGFloat(30)
    // 主体
    let body = CGRect(x: x, y: y, width: w, height: h - 80)
    // 标签页（顶部左侧）
    let tab = CGRect(x: x, y: y + h - 120, width: w * 0.46, height: 130)

    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
    // 渐变坐标跨整个文件夹高度，保证标签页与主体接缝处颜色连续
    let gradient = CGGradient(colorsSpace: srgb, colors: [topColor, bottomColor] as CFArray,
                              locations: [0, 1])!
    let top = CGPoint(x: 0, y: y + h), bottom = CGPoint(x: 0, y: y)

    for rect in [tab, body] {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: top, end: bottom, options: [])
        ctx.restoreGState()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
}

// 主目录（白）：左侧；副目录（琥珀）：右侧，叠在前面
drawFolder(x: 175, y: 500, w: 395, h: 300,
           topColor: CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
           bottomColor: CGColor(srgbRed: 0.87, green: 0.90, blue: 0.97, alpha: 1))
drawFolder(x: 455, y: 500, w: 395, h: 300,
           topColor: CGColor(srgbRed: 1.00, green: 0.80, blue: 0.36, alpha: 1),
           bottomColor: CGColor(srgbRed: 0.97, green: 0.66, blue: 0.22, alpha: 1))

// MARK: - 同步箭头（底部圆弧双箭头）
let arrowCenter = CGPoint(x: 512, y: 318)
let arrowRadius = CGFloat(126)
let stroke = CGFloat(44)

func arrowHeadPath(center: CGPoint, radius: CGFloat, endAngle: CGFloat) -> CGPath {
    let p = CGPoint(x: center.x + radius * cos(endAngle),
                    y: center.y + radius * sin(endAngle))
    let tangent = endAngle + .pi / 2 // 逆时针行进方向的切线
    let dir = CGVector(dx: cos(tangent), dy: sin(tangent))
    let radial = CGVector(dx: cos(endAngle), dy: sin(endAngle))
    let tip = CGPoint(x: p.x + dir.dx * 76, y: p.y + dir.dy * 76)
    let b1 = CGPoint(x: p.x + dir.dx * 4 + radial.dx * 44, y: p.y + dir.dy * 4 + radial.dy * 44)
    let b2 = CGPoint(x: p.x + dir.dx * 4 - radial.dx * 44, y: p.y + dir.dy * 4 - radial.dy * 44)
    let path = CGMutablePath()
    path.move(to: tip)
    path.addLine(to: b1)
    path.addLine(to: b2)
    path.closeSubpath()
    return path
}

let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
ctx.setStrokeColor(white)
ctx.setFillColor(white)
ctx.setLineCap(.round)
ctx.setLineWidth(stroke)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))

for (start, end) in [(CGFloat(35).degreesToRadians, CGFloat(145).degreesToRadians),
                     (CGFloat(215).degreesToRadians, CGFloat(325).degreesToRadians)] {
    ctx.addArc(center: arrowCenter, radius: arrowRadius,
               startAngle: start, endAngle: end, clockwise: false)
    ctx.strokePath()
    ctx.addPath(arrowHeadPath(center: arrowCenter, radius: arrowRadius, endAngle: end))
    ctx.fillPath()
}
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// MARK: - 输出 PNG
let image = ctx.makeImage()!
// swift JIT 解释进程的 currentDirectoryPath 不可靠（可能指向 SDK 目录），
// 相对路径一律基于环境变量 PWD 解析
let fm = FileManager.default
let absOut = outPath.hasPrefix("/")
    ? outPath
    : (ProcessInfo.processInfo.environment["PWD"] ?? fm.currentDirectoryPath) + "/" + outPath
let outURL = URL(fileURLWithPath: absOut)
do {
    try fm.createDirectory(at: outURL.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write("创建输出目录失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("CGImageDestination 创建失败: \(absOut)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("图标写出失败: \(absOut)\n".data(using: .utf8)!)
    exit(1)
}
print("图标已生成: \(absOut)")

extension CGFloat {
    var degreesToRadians: CGFloat { self * .pi / 180 }
}
