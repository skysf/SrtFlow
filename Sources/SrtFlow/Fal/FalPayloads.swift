import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 把要传给 fal 的本地文件包成 data URI
//
// 管什么：图生视频要一张首帧图（`image_url`）。fal 的文件字段既收网址也收 **base64 的 data URI**（fal 各个模型页都写着这一句，
// 「大文件会拖慢请求」），所以不用先上传：本地的图直接编进请求。太大的图（超过 6 MB）或 fal 不认的格式（HEIC……）先用系统的
// ImageIO 缩到长边 2048 像素、存成 JPEG，再编。
// 不管什么：什么时候能读这个文件（AIWorkspace.confirmReading，调用方先问过）、请求体怎么写（FalInputs）。

enum FalPayloads {
    /// 原样编进请求的上限；再大的缩了再传。
    static let maxInlineBytes = 6_000_000
    static let maxLongEdge = 2048

    /// 直接认的图片格式（fal 的图片模型都收）。
    private static let passthrough: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"]

    static func imageDataURI(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            throw FalInputError("SrtFlow could not read the picture \(url.lastPathComponent).")
        }
        if let type = passthrough[url.pathExtension.lowercased()], data.count <= maxInlineBytes {
            return "data:\(type);base64,\(data.base64EncodedString())"
        }
        guard let jpeg = resizedJPEG(data) else {
            throw FalInputError("\(url.lastPathComponent) is not a picture SrtFlow can read (use a PNG, JPEG, WebP or HEIC file).")
        }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// 缩到长边不超过 `maxLongEdge`、存成 JPEG（照片方向按 EXIF 摆正）。读不出来是 nil。
    static func resizedJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
