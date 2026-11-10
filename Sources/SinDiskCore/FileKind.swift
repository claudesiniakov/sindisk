import Foundation

public enum FileKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case folder, app, video, image, audio, archive, diskImage, document, code, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folder: return "Папки"
        case .app: return "Приложения"
        case .video: return "Видео"
        case .image: return "Изображения"
        case .audio: return "Аудио"
        case .archive: return "Архивы"
        case .diskImage: return "Установщики"
        case .document: return "Документы"
        case .code: return "Код"
        case .other: return "Прочее"
        }
    }

    static let extensionMap: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        let groups: [(FileKind, [String])] = [
            (.video, ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts"]),
            (.image, ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3",
                      "nef", "arw", "dng", "psd", "svg", "ico"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "opus", "wma", "caf"]),
            (.archive, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"]),
            (.diskImage, ["dmg", "pkg", "mpkg", "iso", "xip", "img"]),
            (.document, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt",
                         "rtf", "md", "csv", "epub", "odt", "ods"]),
            (.code, ["swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "cpp", "m", "java", "kt", "json",
                     "yml", "yaml", "xml", "html", "css", "sh"]),
        ]
        for (kind, exts) in groups {
            for e in exts { m[e] = kind }
        }
        return m
    }()

    public init(extension ext: String) {
        self = FileKind.extensionMap[ext.lowercased()] ?? .other
    }

    /// Разбор значения фильтра `kind:` (рус./англ. синонимы).
    public static func parse(_ raw: String) -> FileKind? {
        switch raw.lowercased() {
        case "video", "videos", "видео": return .video
        case "image", "images", "photo", "photos", "img", "фото", "изображения", "картинки": return .image
        case "audio", "music", "аудио", "музыка": return .audio
        case "archive", "archives", "архив", "архивы": return .archive
        case "installer", "installers", "dmg", "disk", "установщик", "установщики": return .diskImage
        case "document", "documents", "doc", "docs", "документ", "документы": return .document
        case "code", "код": return .code
        case "app", "apps", "application", "приложение", "приложения", "программа": return .app
        case "folder", "folders", "dir", "папка", "папки": return .folder
        case "other", "прочее": return .other
        default: return nil
        }
    }
}
