import Foundation
#if canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Un serveur HTTP/1.1 minuscule, en sockets POSIX.
///
/// Pas de SwiftNIO ni de Vapor : un binaire statique pour Linux n'a pas
/// besoin d'un framework pour servir une page et quelques requêtes JSON à un
/// seul navigateur, sur `127.0.0.1`. Ce qu'il sait faire, et rien de plus :
/// lire une requête (en-têtes + corps borné), rendre une réponse, et garder
/// une connexion ouverte pour un flux d'événements (`text/event-stream`).
///
/// Chaque connexion a son fil ; la réponse est calculée par un gestionnaire
/// `async`, ce qui laisse le magasin — `@MainActor` — répondre sans qu'on
/// bloque jamais le fil principal.
final class HTTPServer: @unchecked Sendable {
  struct Request {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
  }

  struct Response {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
      self.status = status
      self.headers = headers
      self.body = body
    }

    static func json(_ object: Any, status: Int = 200) -> Response {
      let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
      return Response(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    static func text(_ text: String, status: Int = 200) -> Response {
      Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    static func file(_ url: URL, contentType: String? = nil) -> Response? {
      guard let data = try? Data(contentsOf: url) else { return nil }
      let type = contentType ?? HTTPServer.contentType(forExtension: url.pathExtension)
      return Response(status: 200, headers: ["Content-Type": type, "Cache-Control": "private, max-age=3600"], body: data)
    }

    /// Un flux d'événements : la connexion reste ouverte, le serveur pousse.
    static func eventStream(_ feed: @escaping @Sendable (EventSink) -> Void) -> Response {
      var response = Response(status: 200, headers: [
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
      ])
      response.stream = feed
      return response
    }

    fileprivate var stream: (@Sendable (EventSink) -> Void)?
  }

  /// Ce que le gestionnaire d'un flux reçoit : de quoi écrire, et savoir si
  /// le navigateur est encore là.
  final class EventSink: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private(set) var isOpen = true

    init(fd: Int32) { self.fd = fd }

    /// Envoie un événement ; rend faux si la connexion est morte.
    @discardableResult
    func send(event: String, data: String) -> Bool {
      lock.lock(); defer { lock.unlock() }
      guard isOpen else { return false }
      let lines = data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)" }.joined(separator: "\n")
      let payload = "event: \(event)\n\(lines)\n\n"
      if !HTTPServer.writeAll(fd, Data(payload.utf8)) {
        isOpen = false
        return false
      }
      return true
    }

    func close() {
      lock.lock(); defer { lock.unlock() }
      guard isOpen else { return }
      isOpen = false
      shutdown(fd, Int32(SHUT_RDWR))
      _ = HTTPServer.closeFD(fd)
    }
  }

  typealias Handler = @Sendable (Request) async -> Response

  let port: UInt16
  private let handler: Handler
  private var listenFD: Int32 = -1

  init(port: UInt16, handler: @escaping Handler) {
    self.port = port
    self.handler = handler
  }

  /// Ouvre le port sur `127.0.0.1` seulement — jamais sur le réseau — et rend
  /// le port réellement obtenu (`0` demandait « n'importe lequel »).
  func start() throws -> UInt16 {
    #if canImport(Glibc)
      let streamType = Int32(SOCK_STREAM.rawValue)
    #else
      let streamType = SOCK_STREAM
    #endif
    let fd = socket(AF_INET, streamType, 0)
    guard fd >= 0 else { throw ServerError.socket(errno) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    #if canImport(Darwin)
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    #endif

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { _ = Self.closeFD(fd); throw ServerError.bind(errno) }
    guard listen(fd, 16) == 0 else { _ = Self.closeFD(fd); throw ServerError.listen(errno) }

    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    listenFD = fd
    let obtained = UInt16(bigEndian: actual.sin_port)

    let thread = Thread { [self] in self.acceptLoop() }
    thread.name = "http-accept"
    thread.start()
    return obtained
  }

  private func acceptLoop() {
    while true {
      var peer = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let client = withUnsafeMutablePointer(to: &peer) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &length) }
      }
      guard client >= 0 else {
        if errno == EINTR { continue }
        return
      }
      let thread = Thread { [self] in self.serve(client) }
      thread.name = "http-connection"
      thread.start()
    }
  }

  private func serve(_ fd: Int32) {
    defer { _ = Self.closeFD(fd) }
    // Keep-alive : plusieurs requêtes peuvent se suivre sur la même connexion.
    var buffer = Data()
    while true {
      guard let (request, rest) = readRequest(fd, pending: &buffer) else { return }
      buffer = rest
      let response = Self.wait { await self.handler(request) }
      if let stream = response.stream {
        guard Self.writeAll(fd, Self.head(of: response)) else { return }
        let sink = EventSink(fd: fd)
        stream(sink)
        // Le gestionnaire du flux tient la connexion jusqu'à ce qu'elle
        // tombe ; on ne referme rien ici, et on ne relit rien.
        return
      }
      var complete = response
      complete.headers["Content-Length"] = String(response.body.count)
      complete.headers["Connection"] = "keep-alive"
      guard Self.writeAll(fd, Self.head(of: complete) + response.body) else { return }
    }
  }

  // MARK: - Lecture

  private static let maxBody = 64 * 1024 * 1024

  private func readRequest(_ fd: Int32, pending: inout Data) -> (Request, Data)? {
    var data = pending
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let range = data.range(of: Data("\r\n\r\n".utf8)) {
        let headText = String(decoding: data[data.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = headText.split(separator: "\r\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
          guard let colon = line.firstIndex(of: ":") else { continue }
          let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
          let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
          headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= Self.maxBody else { return nil }
        var body = Data(data[range.upperBound...])
        while body.count < length {
          let n = read(fd, &chunk, chunk.count)
          guard n > 0 else { return nil }
          body.append(contentsOf: chunk[0..<n])
        }
        let rest = body.count > length ? Data(body[body.startIndex.advanced(by: length)...]) : Data()
        body = Data(body.prefix(length))
        let target = String(requestLine[1])
        let (path, query) = Self.split(target)
        let request = Request(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, body: body)
        return (request, rest)
      }
      guard data.count < 1024 * 1024 else { return nil }
      let n = read(fd, &chunk, chunk.count)
      guard n > 0 else { return nil }
      data.append(contentsOf: chunk[0..<n])
    }
  }

  private static func split(_ target: String) -> (String, [String: String]) {
    guard let mark = target.firstIndex(of: "?") else { return (target.removingPercentEncoding ?? target, [:]) }
    let path = String(target[..<mark])
    var query: [String: String] = [:]
    for pair in target[target.index(after: mark)...].split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      let key = parts[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[0]
      let value = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
      query[key] = value
    }
    return (path.removingPercentEncoding ?? path, query)
  }

  // MARK: - Écriture

  private static func head(of response: Response) -> Data {
    var text = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
    for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
      text += "\(name): \(value)\r\n"
    }
    text += "\r\n"
    return Data(text.utf8)
  }

  fileprivate static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
      let n = bytes[offset...].withUnsafeBufferPointer { pointer -> Int in
        #if canImport(Darwin)
          return send(fd, pointer.baseAddress, pointer.count, 0)
        #else
          return send(fd, pointer.baseAddress, pointer.count, Int32(MSG_NOSIGNAL))
        #endif
      }
      if n <= 0 {
        if errno == EINTR { continue }
        return false
      }
      offset += n
    }
    return true
  }

  fileprivate static func closeFD(_ fd: Int32) -> Int32 {
    #if canImport(Musl)
      return Musl.close(fd)
    #elseif canImport(Glibc)
      return Glibc.close(fd)
    #else
      return Darwin.close(fd)
    #endif
  }

  /// Attend une valeur `async` depuis un fil ordinaire — la connexion a son
  /// propre fil, le magasin vit sur l'acteur principal.
  private static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task {
      box.value = await work()
      semaphore.signal()
    }
    semaphore.wait()
    return box.value!
  }

  private final class Box<T>: @unchecked Sendable { var value: T? }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 204: "No Content"
    case 304: "Not Modified"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 413: "Payload Too Large"
    case 500: "Internal Server Error"
    default: "OK"
    }
  }

  static func contentType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "js": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json": "application/json"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "heic": "image/heic"
    case "mp4", "m4v": "video/mp4"
    case "mov": "video/quicktime"
    case "webm": "video/webm"
    case "ogg", "oga", "opus": "audio/ogg"
    case "mp3": "audio/mpeg"
    case "m4a", "aac": "audio/mp4"
    case "wav": "audio/wav"
    case "pdf": "application/pdf"
    case "ttf": "font/ttf"
    case "woff2": "font/woff2"
    case "ico": "image/x-icon"
    default: "application/octet-stream"
    }
  }

  enum ServerError: Error, CustomStringConvertible {
    case socket(Int32), bind(Int32), listen(Int32)
    var description: String {
      switch self {
      case .socket(let e): "socket() : errno \(e)"
      case .bind(let e): "bind() : errno \(e) — le port est-il déjà pris ?"
      case .listen(let e): "listen() : errno \(e)"
      }
    }
  }
}

extension HTTPServer.Request {
  /// Le corps JSON, comme un dictionnaire.
  var json: [String: Any] {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
  }
}
