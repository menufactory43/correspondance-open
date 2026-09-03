// Sous Linux, pas d'AVFoundation : pas de message vocal enregistré depuis l'app.
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox

/// Le vocal qu'on envoie, mis en Ogg/Opus.
///
/// Les tables de capacités des ponts mautrix tranchent **avant** toute
/// conversion : WhatsApp n'accepte qu'`audio/ogg; codecs=opus`, Signal refuse
/// l'AAC dans un `m.audio` vocal. Un `.m4a` revient donc en « unsupported
/// media type » ; l'Ogg/Opus, lui, passe partout — et `AVAudioPlayer` le
/// relit, donc la bulle locale garde le même fichier.
///
/// CoreAudio sait encoder l'Opus, mais seulement dans un CAF : l'écriture
/// directe d'un `.ogg` échoue (`ExtAudioFile` rend « pty? »). On empaquette
/// donc les paquets nous-mêmes, ce qui tient en une poignée de pages.
public enum OggOpusEncoder {
  public enum Failure: Error {
    case encoding(String)
  }

  /// Le type que les ponts attendent d'un vocal. Le paramètre `codecs` n'est
  /// pas décoratif : mautrix-whatsapp n'accepte que celui-là, au caractère près.
  public static let contentType = "audio/ogg; codecs=opus"

  /// Rend un `.ogg` posé à côté de la source, prêt à partir.
  public static func encodeVoiceNote(from source: URL) async throws -> URL {
    let destination = source.deletingPathExtension().appendingPathExtension("ogg")
    // Hors de l'acteur principal : encoder une minute de parole prend le temps
    // qu'il prend, et l'interface continue de suivre le doigt.
    try await Task.detached(priority: .userInitiated) { try encode(source, to: destination) }.value
    return destination
  }

  static func encode(_ source: URL, to destination: URL) throws {
    let caf = destination.appendingPathExtension("caf")
    defer { try? FileManager.default.removeItem(at: caf) }
    try transcodeToOpusCAF(source, to: caf)
    let stream = try packets(of: caf)
    try mux(stream).write(to: destination, options: [.atomic])
  }

  /// Le fichier enregistré (AAC 44,1 kHz) relu en PCM 48 kHz mono, puis
  /// réencodé en Opus — le seul débit qu'Opus connaisse.
  private static func transcodeToOpusCAF(_ source: URL, to caf: URL) throws {
    try? FileManager.default.removeItem(at: caf)
    let input = try AVAudioFile(forReading: source)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
          let converter = AVAudioConverter(from: input.processingFormat, to: format)
    else { throw Failure.encoding("rééchantillonnage impossible") }
    let output = try AVAudioFile(forWriting: caf, settings: [
      AVFormatIDKey: kAudioFormatOpus,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ])
    while true {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000) else { break }
      var failure: NSError?
      let status = converter.convert(to: buffer, error: &failure) { _, state in
        guard let piece = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192),
              (try? input.read(into: piece)) != nil, piece.frameLength > 0
        else {
          state.pointee = .endOfStream
          return nil
        }
        state.pointee = .haveData
        return piece
      }
      if let failure { throw failure }
      if buffer.frameLength > 0 { try output.write(from: buffer) }
      if status == .endOfStream || status == .error { break }
    }
  }

  /// Ce qu'un flux Opus demande pour être relu : ses paquets, le nombre
  /// d'échantillons que l'encodeur a ajoutés devant (`pre-skip`) et celui des
  /// échantillons qui comptent vraiment.
  struct Stream {
    var packets: [[UInt8]] = []
    var preSkip: UInt16 = 312
    var validFrames: UInt64 = 0
  }

  private static func packets(of caf: URL) throws -> Stream {
    var file: AudioFileID?
    guard AudioFileOpenURL(caf as CFURL, .readPermission, 0, &file) == noErr, let file else {
      throw Failure.encoding("CAF illisible")
    }
    defer { AudioFileClose(file) }

    var count: UInt64 = 0
    var size = UInt32(MemoryLayout<UInt64>.size)
    AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &count)
    var largest: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    AudioFileGetProperty(file, kAudioFilePropertyMaximumPacketSize, &size, &largest)
    guard count > 0, largest > 0 else { throw Failure.encoding("flux Opus vide") }

    var stream = Stream()
    var table = AudioFilePacketTableInfo()
    size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
    if AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr {
      stream.preSkip = UInt16(clamping: table.mPrimingFrames)
      stream.validFrames = UInt64(clamping: table.mNumberValidFrames)
    }

    var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: Int(count))
    var bytes = [UInt8](repeating: 0, count: Int(count) * Int(largest))
    var read = UInt32(count)
    var byteCount = UInt32(bytes.count)
    let status = bytes.withUnsafeMutableBytes {
      AudioFileReadPacketData(file, false, &byteCount, &descriptions, 0, &read, $0.baseAddress)
    }
    guard status == noErr, read > 0 else { throw Failure.encoding("paquets Opus illisibles") }
    stream.packets = (0..<Int(read)).map { index in
      let start = Int(descriptions[index].mStartOffset)
      return Array(bytes[start..<(start + Int(descriptions[index].mDataByteSize))])
    }
    if stream.validFrames == 0 {
      stream.validFrames = UInt64(read) * 960 - UInt64(stream.preSkip)
    }
    return stream
  }

  /// Les pages Ogg : l'en-tête `OpusHead`, les commentaires, puis l'audio.
  /// La position granulaire compte les échantillons décodés depuis le début,
  /// pre-skip compris ; celle de la dernière page dit où couper.
  static func mux(_ stream: Stream) -> Data {
    let serial = UInt32.random(in: 1...UInt32.max)
    var data = Data()
    var page = UInt32(0)

    var head = Data("OpusHead".utf8)
    head.append(contentsOf: [1, 1])
    head.append(littleEndian: stream.preSkip)
    head.append(littleEndian: UInt32(48_000))
    head.append(contentsOf: [0, 0, 0])
    data += self.page([[UInt8](head)], granule: 0, serial: serial, index: &page, flags: 2)

    var tags = Data("OpusTags".utf8)
    let vendor = Data("Correspondance".utf8)
    tags.append(littleEndian: UInt32(vendor.count))
    tags += vendor
    tags.append(littleEndian: UInt32(0))
    data += self.page([[UInt8](tags)], granule: 0, serial: serial, index: &page, flags: 0)

    let last = UInt64(stream.preSkip) + stream.validFrames
    var granule = UInt64(0)
    var batch: [[UInt8]] = []
    var segments = 0
    for (index, packet) in stream.packets.enumerated() {
      let needed = packet.count / 255 + 1
      if segments + needed > 255 {
        data += self.page(batch, granule: granule, serial: serial, index: &page, flags: 0)
        batch = []
        segments = 0
      }
      batch.append(packet)
      segments += needed
      granule += 960
      if index == stream.packets.count - 1 {
        data += self.page(batch, granule: last, serial: serial, index: &page, flags: 4)
      }
    }
    return data
  }

  private static func page(
    _ packets: [[UInt8]], granule: UInt64, serial: UInt32, index: inout UInt32, flags: UInt8
  ) -> Data {
    var lacing: [UInt8] = []
    for packet in packets {
      var remaining = packet.count
      while remaining >= 255 {
        lacing.append(255)
        remaining -= 255
      }
      lacing.append(UInt8(remaining))
    }
    var header = Data("OggS".utf8)
    header.append(contentsOf: [0, flags])
    header.append(littleEndian: granule)
    header.append(littleEndian: serial)
    header.append(littleEndian: index)
    header.append(littleEndian: UInt32(0))
    header.append(UInt8(lacing.count))
    header.append(contentsOf: lacing)
    var body = header
    for packet in packets { body.append(contentsOf: packet) }
    let sum = crc32(body)
    body.replaceSubrange(22..<26, with: withUnsafeBytes(of: sum.littleEndian) { Data($0) })
    index += 1
    return body
  }

  /// Le CRC d'Ogg : le polynôme habituel, mais sans miroir ni inversion.
  private static let crcTable: [UInt32] = (0..<256).map { byte in
    var value = UInt32(byte) << 24
    for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
    return value
  }

  private static func crc32(_ bytes: Data) -> UInt32 {
    bytes.reduce(UInt32(0)) { sum, byte in (sum << 8) ^ crcTable[Int((sum >> 24) ^ UInt32(byte))] }
  }
}

private extension Data {
  mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}

#endif
