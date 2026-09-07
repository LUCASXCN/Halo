//
//  ImageEngine.swift — 图像解码、缩略图、按屏幕物理像素「充满屏·居中裁剪」
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageEngine {

    /// 主屏物理像素（点 × 缩放因子），多屏取主屏
    static func mainScreenPixel() -> CGSize {
        guard let s = NSScreen.screens.first else { return CGSize(width: 4112, height: 2658) }
        let f = s.backingScaleFactor
        return CGSize(width: s.frame.width * f, height: s.frame.height * f)
    }

    /// 轻量缩略图（列表/预览用）
    static func thumbnail(at url: URL, maxEdge: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxEdge * 2)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 把任意图按主屏物理像素 aspect-fill 裁成同尺寸 PNG，写到 outURL。
    /// 这样交给系统当壁纸时必然铺满全屏、无留边、不拉伸。
    @discardableResult
    static func fillScreenPNG(_ inURL: URL, outURL: URL) -> Bool {
        let target = mainScreenPixel()
        guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return false }
        let scale = max(target.width / w, target.height / h)
        let dw = w * scale, dh = h * scale
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(target.width, target.height) * 1.2)
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let ctx = CGContext(data: nil, width: Int(target.width), height: Int(target.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: (target.width - dw) / 2, y: (target.height - dh) / 2,
                                   width: dw, height: dh))
        guard let cg = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? data.write(to: outURL, options: .atomic)
        return true
    }
}
