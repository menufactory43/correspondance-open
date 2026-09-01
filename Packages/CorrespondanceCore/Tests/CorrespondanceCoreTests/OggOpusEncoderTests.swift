import AVFoundation
import XCTest
@testable import CorrespondanceCore

/// Le vocal qui part doit être un Ogg/Opus valide : c'est le seul format que
/// Signal, WhatsApp et Messenger acceptent tous les trois.
final class OggOpusEncoderTests: XCTestCase {
  /// Deux secondes de la 440, enregistrées comme le magnétophone les écrit.
  private func sourceM4A() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ogg-opus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("source.m4a")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let frames = AVAudioFrameCount(88_200)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
      buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 440 * Double(index) / 44_100)) * 0.5
    }
    // Le fichier ne se ferme qu'à la disparition de l'objet : relire avant,
    // c'est lire un en-tête inachevé.
    try {
      let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
      ])
      try file.write(from: buffer)
    }()
    return url
  }

  func testLeVocalEncodeEstUnOggOpusLisible() async throws {
    let source = try sourceM4A()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let ogg = try await OggOpusEncoder.encodeVoiceNote(from: source)
    XCTAssertEqual(ogg.pathExtension, "ogg")
    let data = try Data(contentsOf: ogg)
    XCTAssertGreaterThan(data.count, 2_000)
    XCTAssertEqual(data.prefix(4), Data("OggS".utf8))
    let texte = String(decoding: data.prefix(200), as: UTF8.self)
    XCTAssertTrue(texte.contains("OpusHead"))
    XCTAssertTrue(texte.contains("OpusTags"))
    // Version 1, un canal, 48 kHz : ce que dit l'en-tête juste après la magie.
    let head = try XCTUnwrap(range(of: Data("OpusHead".utf8), in: data))
    XCTAssertEqual(data[head + 8], 1)
    XCTAssertEqual(data[head + 9], 1)
    let preSkip = UInt16(data[head + 10]) | UInt16(data[head + 11]) << 8

    // La dernière page porte le drapeau de fin de flux et la durée réelle.
    let derniere = try XCTUnwrap(pages(in: data).last)
    XCTAssertEqual(derniere.flags & 4, 4)
    XCTAssertEqual(Double(derniere.granule), 96_000 + Double(preSkip), accuracy: 1_000)

    // C'est ce lecteur-là qui rejouera la bulle, sur le Mac comme sur l'iPhone.
    let player = try AVAudioPlayer(contentsOf: ogg)
    XCTAssertEqual(player.duration, 2, accuracy: 0.1)

    guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") else { return }
    XCTAssertEqual(shell("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-i", ogg.path, "-f", "null", "-"]).0, 0)
    let sonde = shell("/opt/homebrew/bin/ffprobe", [
      "-v", "error", "-select_streams", "a:0",
      "-show_entries", "stream=codec_name,sample_rate,channels",
      "-of", "csv=p=0", ogg.path,
    ]).1
    XCTAssertEqual(sonde.trimmingCharacters(in: .whitespacesAndNewlines), "opus,48000,1")
  }

  private func range(of needle: Data, in data: Data) -> Int? {
    data.range(of: needle).map { $0.lowerBound }
  }

  private func pages(in data: Data) -> [(flags: UInt8, granule: UInt64)] {
    var found: [(UInt8, UInt64)] = []
    var index = data.startIndex
    while let start = data.range(of: Data("OggS".utf8), in: index..<data.endIndex)?.lowerBound {
      let granule = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[start + 6 + $1]) << (8 * UInt64($1)) }
      found.append((data[start + 5], granule))
      index = start + 4
    }
    return found
  }

  private func shell(_ launch: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launch)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
  }
}
