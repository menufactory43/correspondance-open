import XCTest
@testable import CorrespondanceCore

/// Un vocal se reconnaît à `org.matrix.msc3245.voice` — et à rien d'autre.
/// Sa durée et sa forme d'onde viennent de `org.matrix.msc1767.audio`.
final class VoiceNoteTests: XCTestCase {
  private func content(_ json: String) throws -> MatrixJSON {
    try JSONDecoder().decode(MatrixJSON.self, from: Data(json.utf8))
  }

  func testUnAudioSansLaCleMSC3245ResteUnFichier() throws {
    let contenu = try content(#"{"msgtype":"m.audio","url":"mxc://a/b","info":{"duration":7000}}"#)
    XCTAssertNil(MatrixSyncParser.voiceNote(in: contenu, msgtype: "m.audio"))
  }

  func testLaPresenceDeLaCleSuffitAFaireUnVocal() throws {
    let contenu = try content(#"""
    {"msgtype":"m.audio","url":"mxc://a/b",
     "org.matrix.msc3245.voice":{},
     "org.matrix.msc1767.audio":{"duration":7250,"waveform":[0,512,1024]}}
    """#)
    let vocal = try XCTUnwrap(MatrixSyncParser.voiceNote(in: contenu, msgtype: "m.audio"))
    XCTAssertEqual(vocal.duration, 7.25, accuracy: 0.001)
    XCTAssertEqual(vocal.waveform, [0, 0.5, 1])
    XCTAssertEqual(vocal.durationLabel, "0:07")
  }

  func testSansMSC1767LaDureeVientDeInfo() throws {
    let contenu = try content(#"""
    {"msgtype":"m.audio","url":"mxc://a/b","info":{"duration":3000},
     "org.matrix.msc3245.voice":{}}
    """#)
    let vocal = try XCTUnwrap(MatrixSyncParser.voiceNote(in: contenu, msgtype: "m.audio"))
    XCTAssertEqual(vocal.duration, 3, accuracy: 0.001)
    XCTAssertTrue(vocal.waveform.isEmpty)
  }

  func testUneImageNEstJamaisUnVocal() throws {
    let contenu = try content(#"{"msgtype":"m.image","url":"mxc://a/b","org.matrix.msc3245.voice":{}}"#)
    XCTAssertNil(MatrixSyncParser.voiceNote(in: contenu, msgtype: "m.image"))
  }

  func testLeSyncPoseLeVocalSurLaPieceJointe() throws {
    let json = """
    {"next_batch":"s2","rooms":{"join":{"!a:relais":{
      "state":{"events":[{"type":"m.bridge","state_key":"","content":{"protocol":{"id":"whatsappgo"}}}]},
      "timeline":{"events":[{
        "type":"m.room.message","event_id":"$1","sender":"@whatsapp_lid-1:relais",
        "origin_server_ts":1800000000000,
        "content":{"msgtype":"m.audio","body":"vocal.ogg","url":"mxc://a/b",
          "info":{"mimetype":"audio/ogg","duration":5000},
          "org.matrix.msc3245.voice":{},
          "org.matrix.msc1767.audio":{"duration":5000,"waveform":[256,768]}}
      }]}}}}}
    """
    let parser = MatrixSyncParser(selfUserID: "@meffysto:relais")
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8)), to: &rooms)

    let message = try XCTUnwrap(rooms["!a:relais"]?.messagesByID["$1"])
    let piece = try XCTUnwrap(message.attachments.first)
    XCTAssertTrue(piece.isVoiceNote)
    XCTAssertTrue(piece.isAudio)
    XCTAssertEqual(piece.voice?.duration, 5)
    XCTAssertEqual(message.sidebarPreviewText, "🎤 Message vocal")
  }

  // MARK: - La forme d'onde

  func testLaFormeDOndeSeRamèneAuNombreDeBarresDeLaBulle() {
    let vocal = VoiceNote(duration: 10, waveform: [0, 0.25, 0.5, 0.75, 1, 1, 0.5, 0])
    XCTAssertEqual(vocal.bars(4).count, 4)
    XCTAssertEqual(vocal.bars(4)[0], 0.125, accuracy: 0.001)
    // Une forme d'onde plus courte que demandée se complète, elle ne s'invente pas.
    XCTAssertEqual(VoiceNote(waveform: [1]).bars(3), [1, 0, 0])
    // Sans forme d'onde du tout, une barre neutre plutôt qu'un vide.
    XCTAssertEqual(VoiceNote().bars(3), [0.25, 0.25, 0.25])
  }

  func testLAllerRetourDeLEchelleMSC1767() {
    let vocal = VoiceNote(duration: 1, waveform: VoiceNote.normalized([0, 512, 1024]))
    XCTAssertEqual(vocal.encodedWaveform, [0, 512, 1024])
  }

  func testLesDecibelsDuMicroSeRabattentEntreZeroEtUn() {
    XCTAssertEqual(VoiceRecorder.normalized(decibels: 0), 1, accuracy: 0.001)
    XCTAssertEqual(VoiceRecorder.normalized(decibels: -25), 0.5, accuracy: 0.001)
    XCTAssertEqual(VoiceRecorder.normalized(decibels: -160), 0)
    XCTAssertEqual(VoiceRecorder.normalized(decibels: .infinity), 0)
  }
}
