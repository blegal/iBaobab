import AppKit
import Synchronization
import UniformTypeIdentifiers

/// Catégorie de fichier utilisée pour colorer les vues d'occupation du disque.
enum DiskCategory: Int, CaseIterable {
    case images, video, audio, documents, code, data, archives, other

    var title: String {
        switch self {
        case .images: "Images"
        case .video: "Vidéo"
        case .audio: "Audio"
        case .documents: "Documents"
        case .code: "Code"
        case .data: "Données"
        case .archives: "Archives"
        case .other: "Autres"
        }
    }

    var color: NSColor { Self.colors[rawValue] }

    private static let colors = ["#3A9D5D", "#D6504B", "#9466CF", "#3A7BD5", "#E3872D", "#169FA6", "#C4579B", "#8D9097"].map(NSColor.init(hex:))

    private static let table: [String: DiskCategory] = {
        var table: [String: DiskCategory] = [:]
        let groups: [(DiskCategory, String)] = [
            (.images, "jpg jpeg png heic heif gif tiff tif bmp webp svg cr2 cr3 nef arw dng raw psd ico icns"),
            (.video, "mov mp4 m4v mkv avi webm mts mpg mpeg wmv flv"),
            (.audio, "m4a wav mp3 flac aac aif aiff ogg opus caf alac"),
            (.documents, "pdf doc docx tex md txt rtf pages key numbers pptx ppt xlsx xls odt ods odp bib epub html htm"),
            (.code, "c h cc cpp hpp m mm swift py ipynb js ts tsx jsx java kt rs go rb php sh zsh json yaml yml toml xml css scss sql lua pl r jl"),
            (.data, "h5 hdf5 mat npy npz csv tsv nc parquet feather db sqlite sqlite3 bin dat pkl pt pth onnx safetensors"),
            (.archives, "zip gz tgz bz2 xz 7z rar tar dmg iso pkg xip zst"),
        ]
        for (category, extensions) in groups {
            for ext in extensions.split(separator: " ") { table[String(ext)] = category }
        }
        return table
    }()
    private static var cache: [String: DiskCategory] = [:]
    private static let lock = NSLock()

    /// Catégorie d'après l'extension du nom (octets UTF-8). `local` est propre à une branche de l'analyse :
    /// le verrou n'est pris que pour une extension inconnue de cette branche.
    static func of(nameBytes name: UnsafeBufferPointer<UInt8>, cache local: inout [String: DiskCategory]) -> DiskCategory {
        // Pas d'extension : sans point, ou point initial (fichier caché).
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, (1...32).contains(name.count - dot - 1) else { return .other }
        let ext = String(decoding: UnsafeBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self).lowercased()
        if let known = table[ext] ?? local[ext] { return known }
        let category = shared(ext)
        local[ext] = category
        return category
    }

    /// Table, puis UTType, mis en cache ; utilisable depuis plusieurs fils.
    private static func shared(_ ext: String) -> DiskCategory {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[ext] { return cached }
        var category = DiskCategory.other
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { category = .images }
            else if type.conforms(to: .movie) { category = .video }
            else if type.conforms(to: .audio) { category = .audio }
            else if type.conforms(to: .sourceCode) || type.conforms(to: .script) { category = .code }
            else if type.conforms(to: .archive) || type.conforms(to: .diskImage) { category = .archives }
            else if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { category = .documents }
        }
        cache[ext] = category
        return category
    }
}

/// Tailles par catégorie (une par `DiskCategory`), sans allocation.
typealias CategorySizes = InlineArray<8, Int64>

/// Nœud compact de l'arbre d'occupation : un fichier, un dossier ou un groupe de petits fichiers.
/// 64 octets par nœud : un fichier n'a que son nom, sa taille et un mot de 64 bits (nombre, catégorie, date) ;
/// dossiers et groupes ont en plus un `Contents` (enfants, tailles par catégorie).
final class DiskNode {
    let name: String
    /// Le parent possède ses enfants : une référence `unowned` évite la table annexe d'une référence faible.
    unowned var parent: DiskNode?
    var size: Int64 = 0
    /// Nombre de fichiers (28 bits), catégorie (3 bits), groupe (1 bit), date de modification (32 bits, secondes depuis 1970).
    private var bits: UInt64 = 0
    private var contents: Contents?

    /// Partie propre aux dossiers et aux groupes.
    private class Contents {
        var children: [DiskNode]?
        var sizes = CategorySizes(repeating: 0)
    }

    /// Racine de l'analyse : seule à connaître son URL.
    private final class RootContents: Contents {
        var rootURL: URL?
    }

    init(name: String) { self.name = name }

    private static let countMask: UInt64 = 0x0FFF_FFFF

    /// Nombre de fichiers (1 pour un fichier, total des descendants pour un dossier ou un groupe).
    var count: Int {
        get { Int(bits & Self.countMask) }
        set { bits = bits & ~Self.countMask | UInt64(min(max(newValue, 0), Int(Self.countMask))) }
    }

    var category: DiskCategory {
        get { DiskCategory(rawValue: Int(bits >> 28 & 7)) ?? .other }
        set { bits = bits & ~(7 << 28) | UInt64(newValue.rawValue) << 28 }
    }

    /// Groupe « N autres fichiers » (les petits fichiers d'un dossier, agrégés pour économiser la mémoire).
    var isAggregate: Bool {
        get { bits & 1 << 31 != 0 }
        set { bits = newValue ? bits | 1 << 31 : bits & ~(1 << 31) }
    }

    /// Date de modification la plus récente en secondes depuis 1970 (0 si inconnue).
    var modifiedSeconds: UInt32 {
        get { UInt32(bits >> 32) }
        set { bits = bits & 0xFFFF_FFFF | UInt64(newValue) << 32 }
    }

    /// Date de modification la plus récente (secondes depuis la date de référence, 0 si inconnue).
    var modified: TimeInterval {
        let seconds = modifiedSeconds
        return seconds == 0 ? 0 : TimeInterval(seconds) - Date.timeIntervalBetween1970AndReferenceDate
    }

    /// Dossiers seulement (nil pour un fichier ou un groupe).
    var children: [DiskNode]? {
        get { contents?.children }
        set { makeContents().children = newValue }
    }

    /// Racine de l'analyse uniquement.
    var rootURL: URL? {
        get { (contents as? RootContents)?.rootURL }
        set {
            let root = contents as? RootContents ?? RootContents()
            if root !== contents {
                root.children = contents?.children
                root.sizes = contents?.sizes ?? root.sizes
                contents = root
            }
            root.rootURL = newValue
        }
    }

    private func makeContents() -> Contents {
        if let contents { return contents }
        let created = Contents()
        contents = created
        return created
    }

    var isDirectory: Bool { contents?.children != nil }
    var url: URL { rootURL ?? parent?.url.appendingPathComponent(name, isDirectory: isDirectory) ?? URL(fileURLWithPath: name) }

    /// Taille d'une catégorie (répartition des dossiers et des groupes, catégorie propre d'un fichier).
    func size(of category: DiskCategory) -> Int64 {
        if let contents { return contents.sizes[category.rawValue] }
        return category == self.category ? size : 0
    }

    /// Ajoute la répartition par catégorie du nœud à `sizes`.
    func accumulate(into sizes: inout CategorySizes, sign: Int64 = 1) {
        if let contents {
            for index in sizes.indices { sizes[index] += sign * contents.sizes[index] }
        } else {
            sizes[category.rawValue] += sign * size
        }
    }

    /// Groupe de petits éléments, d'après leurs totaux.
    static func group(name: String, size: Int64, count: Int, modified: UInt32, sizes: CategorySizes) -> DiskNode {
        let group = DiskNode(name: name)
        group.isAggregate = true
        group.makeContents().sizes = sizes
        group.size = size
        group.count = count
        group.modifiedSeconds = modified
        group.category = sizes.dominant
        return group
    }

    /// Groupe de nœuds existants (taille, nombre, date et répartition cumulés).
    static func group(name: String, of items: some Sequence<DiskNode>) -> DiskNode {
        var sizes = CategorySizes(repeating: 0)
        var total: Int64 = 0, count = 0, modified: UInt32 = 0
        for item in items {
            total += item.size
            count += item.count
            modified = max(modified, item.modifiedSeconds)
            item.accumulate(into: &sizes)
        }
        return group(name: name, size: total, count: count, modified: modified, sizes: sizes)
    }

    /// Recalcule les totaux à partir des enfants et les trie du plus gros au plus petit.
    func finish() {
        guard let contents, contents.children != nil else { return }
        contents.children!.sort { $0.size > $1.size }
        var sizes = CategorySizes(repeating: 0)
        var total: Int64 = 0, count = 0, modified: UInt32 = 0
        for kid in contents.children! {
            total += kid.size
            count += kid.count
            modified = max(modified, kid.modifiedSeconds)
            kid.accumulate(into: &sizes)
        }
        contents.sizes = sizes
        size = total
        self.count = count
        modifiedSeconds = modified
        category = sizes.dominant
    }

    /// Sous-dossier désigné par un chemin relatif.
    func descendant(_ components: [String]) -> DiskNode? {
        var node = self
        for component in components {
            guard let next = node.children?.first(where: { $0.isDirectory && $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Détache le nœud (après une mise à la corbeille) et retire sa taille de ses ancêtres.
    func detach() {
        guard let parent else { return }
        parent.contents?.children?.removeAll { $0 === self }
        var ancestor: DiskNode? = parent
        while let node = ancestor {
            node.size -= size
            node.count -= count
            if let contents = node.contents {
                accumulate(into: &contents.sizes, sign: -1)
                contents.children?.sort { $0.size > $1.size }
            }
            ancestor = node.parent
        }
        self.parent = nil
    }
}

extension CategorySizes {
    /// Catégorie qui pèse le plus.
    var dominant: DiskCategory {
        var best = 0
        for index in indices where self[index] > self[best] { best = index }
        return DiskCategory(rawValue: best) ?? .other
    }
}

/// Analyse récursive d'un dossier, en arrière-plan, parallélisée sur les premiers niveaux.
/// Chaque dossier est lu par `getattrlistbulk` : un appel système pour des centaines d'entrées,
/// avec seulement les attributs utiles (nom, type, date, taille allouée, point de montage).
final class DiskScanner: @unchecked Sendable {
    /// Fichiers gardés individuellement par dossier ; les autres sont regroupés.
    static let keptFilesPerFolder = 200

    private let scannedFiles = Atomic<Int>(0)
    private let scannedBytes = Atomic<Int64>(0)
    private let cancelled = Atomic<Bool>(false)
    /// Sous-arbres déjà analysés, réutilisés tels quels (par chemin).
    private let reuse: [String: DiskNode]

    init(reuse: [String: DiskNode] = [:]) { self.reuse = reuse }

    var progress: (files: Int, bytes: Int64) {
        (scannedFiles.load(ordering: .relaxed), scannedBytes.load(ordering: .relaxed))
    }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() { cancelled.store(true, ordering: .relaxed) }

    /// Arbre du dossier, ou nil si l'analyse a été annulée.
    func scan(_ url: URL) -> DiskNode? {
        var cache = BranchCache()
        let root = directory(url.standardizedFileURL.path, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                             depth: 0, cache: &cache)
        guard !isCancelled else { return nil }
        root.rootURL = url
        return root
    }

    /// Caches propres à une branche de l'analyse (pas de verrou) : catégories des extensions
    /// et noms longs déjà vus, partagés entre nœuds (« Info.plist », « Localizable.strings »…).
    private struct BranchCache {
        var categories: [String: DiskCategory] = [:]
        var names = Set<String>()

        /// Les noms de plus de 15 octets occupent une allocation : un nom déjà vu est réutilisé.
        mutating func name(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
            let name = String(decoding: bytes, as: UTF8.self)
            guard bytes.count > 15 else { return name }
            return names.insert(name).memberAfterInsert
        }
    }

    /// Fichier lu, avant de devenir un nœud (seuls les plus gros en deviennent un).
    private struct File {
        let name: String
        let size: Int64
        let modified: UInt32
        let category: DiskCategory
    }

    private func directory(_ path: String, name: String, depth: Int, cache: inout BranchCache) -> DiskNode {
        if depth > 0, !reuse.isEmpty, let cached = reuse[path] {
            cached.parent = nil
            add(files: cached.count, bytes: cached.size)
            return cached
        }
        var files: [File] = []
        var folders: [String] = []
        var bytes: Int64 = 0
        Self.list(path) { entry in
            switch entry.kind {
            case .folder:
                folders.append(cache.name(entry.name))
            case .mountPoint:
                break // Pas de traversée des points de montage (autres volumes).
            case .file:
                let category = DiskCategory.of(nameBytes: entry.name, cache: &cache.categories)
                files.append(File(name: cache.name(entry.name), size: entry.allocated, modified: entry.modified, category: category))
                bytes += entry.allocated
            }
        }
        add(files: files.count, bytes: bytes)

        let prefix = path == "/" ? "/" : path + "/"
        var subfolders: [DiskNode]
        if depth < 2, folders.count > 1 {
            var results = [DiskNode?](repeating: nil, count: folders.count)
            results.withUnsafeMutableBufferPointer { slots in
                nonisolated(unsafe) let slots = slots
                DispatchQueue.concurrentPerform(iterations: folders.count) { index in
                    guard !isCancelled else { return }
                    // Chaque branche a son cache d'extensions : pas de verrou partagé.
                    var branchCache = BranchCache()
                    slots[index] = directory(prefix + folders[index], name: folders[index], depth: depth + 1, cache: &branchCache)
                }
            }
            subfolders = results.compactMap { $0 }
        } else {
            subfolders = []
            subfolders.reserveCapacity(folders.count)
            for folder in folders {
                if isCancelled { break }
                subfolders.append(directory(prefix + folder, name: folder, depth: depth + 1, cache: &cache))
            }
        }

        // Seuls les plus gros fichiers deviennent des nœuds ; les autres forment un groupe.
        let kept = Self.keptFilesPerFolder
        if files.count > kept { files.sort { $0.size > $1.size } }
        var children = subfolders
        children.reserveCapacity(subfolders.count + min(files.count, kept + 1))
        for file in files.prefix(kept) {
            let node = DiskNode(name: file.name)
            node.size = file.size
            node.count = 1
            node.modifiedSeconds = file.modified
            node.category = file.category
            children.append(node)
        }
        if files.count > kept {
            let rest = files[kept...]
            var sizes = CategorySizes(repeating: 0)
            var total: Int64 = 0, modified: UInt32 = 0
            for file in rest {
                total += file.size
                modified = max(modified, file.modified)
                sizes[file.category.rawValue] += file.size
            }
            children.append(DiskNode.group(name: "\(rest.count) autres fichiers", size: total, count: rest.count, modified: modified, sizes: sizes))
        }
        let node = DiskNode(name: name)
        for child in children { child.parent = node }
        node.children = children
        node.finish()
        return node
    }

    private func add(files: Int, bytes: Int64) {
        scannedFiles.add(files, ordering: .relaxed)
        scannedBytes.add(bytes, ordering: .relaxed)
    }

    // MARK: Lecture d'un dossier

    private enum Kind { case file, folder, mountPoint }

    private struct Entry {
        let kind: Kind
        /// Nom en UTF-8 (sans le zéro final), valable pendant l'appel seulement.
        let name: UnsafeBufferPointer<UInt8>
        let allocated: Int64
        let modified: UInt32
    }

    private static let bufferSize = 64 * 1024

    /// Énumère les entrées d'un dossier (y compris cachées) ; rien si le dossier est illisible.
    private static func list(_ path: String, _ body: (Entry) -> Void) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_ERROR)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            guard count > 0 else { return }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                // Seuls les attributs renvoyés sont présents, dans l'ordre ; l'erreur éventuelle vient en premier.
                let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                var field = entry + 4 + MemoryLayout<attribute_set_t>.size
                func has(_ group: attrgroup_t, _ attribute: some BinaryInteger) -> Bool { group & attrgroup_t(attribute) != 0 }
                if has(returned.commonattr, ATTR_CMN_ERROR) {
                    guard field.loadUnaligned(as: UInt32.self) == 0 else { continue }
                    field += 4
                }
                guard has(returned.commonattr, ATTR_CMN_NAME), has(returned.commonattr, ATTR_CMN_OBJTYPE) else { continue }
                let nameReference = field.loadUnaligned(as: attrreference_t.self)
                let nameStart = field + Int(nameReference.attr_dataoffset)
                field += MemoryLayout<attrreference_t>.size
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size
                var seconds: UInt32 = 0
                if has(returned.commonattr, ATTR_CMN_MODTIME) {
                    seconds = UInt32(clamping: field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var mountStatus: UInt32 = 0
                if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
                    mountStatus = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var size: Int64 = 0
                if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { size = max(0, Int64(field.loadUnaligned(as: off_t.self))) }

                guard nameReference.attr_length > 1 else { continue }
                let name = UnsafeBufferPointer(start: nameStart.assumingMemoryBound(to: UInt8.self), count: Int(nameReference.attr_length) - 1)
                let kind: Kind
                if type == fsobj_type_t(VDIR.rawValue) {
                    kind = mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0 ? .mountPoint : .folder
                    size = 0
                } else {
                    kind = .file
                }
                body(Entry(kind: kind, name: name, allocated: size, modified: seconds))
            }
        }
    }
}
