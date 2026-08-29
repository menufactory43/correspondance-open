#!/usr/bin/env python3
"""Fabrique la fixture `chat.db` réduite des tests iMessage.

Le schéma est celui de macOS 26 (`sqlite3 ~/Library/Messages/chat.db ".schema"`),
tables utiles seulement, sans index ni déclencheur. Les données sont inventées :
aucune conversation réelle n'entre dans le dépôt.

    python3 scripts/make-imessage-fixture.py
"""

import os
import plistlib
import sqlite3
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "..", "CorrespondanceTests", "Fixtures", "imessage-macos26.db")

# Colonnes verbatim de macOS 26 — la fixture doit casser si le schéma bouge.
SCHEMA = """
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT, replace INTEGER DEFAULT 0, service_center TEXT, handle_id INTEGER DEFAULT 0, subject TEXT, country TEXT, attributedBody BLOB, version INTEGER DEFAULT 0, type INTEGER DEFAULT 0, service TEXT, account TEXT, account_guid TEXT, error INTEGER DEFAULT 0, date INTEGER, date_read INTEGER, date_delivered INTEGER, is_delivered INTEGER DEFAULT 0, is_finished INTEGER DEFAULT 0, is_emote INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, is_empty INTEGER DEFAULT 0, is_delayed INTEGER DEFAULT 0, is_auto_reply INTEGER DEFAULT 0, is_prepared INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, is_system_message INTEGER DEFAULT 0, is_sent INTEGER DEFAULT 0, has_dd_results INTEGER DEFAULT 0, is_service_message INTEGER DEFAULT 0, is_forward INTEGER DEFAULT 0, was_downgraded INTEGER DEFAULT 0, is_archive INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0, cache_roomnames TEXT, was_data_detected INTEGER DEFAULT 0, was_deduplicated INTEGER DEFAULT 0, is_audio_message INTEGER DEFAULT 0, is_played INTEGER DEFAULT 0, date_played INTEGER, item_type INTEGER DEFAULT 0, other_handle INTEGER DEFAULT 0, group_title TEXT, group_action_type INTEGER DEFAULT 0, share_status INTEGER DEFAULT 0, share_direction INTEGER DEFAULT 0, is_expirable INTEGER DEFAULT 0, expire_state INTEGER DEFAULT 0, message_action_type INTEGER DEFAULT 0, message_source INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, payload_data BLOB, expressive_send_style_id TEXT, associated_message_range_location INTEGER DEFAULT 0, associated_message_range_length INTEGER DEFAULT 0, time_expressive_send_played INTEGER, message_summary_info BLOB, ck_sync_state INTEGER DEFAULT 0, ck_record_id TEXT, ck_record_change_tag TEXT, destination_caller_id TEXT, is_corrupt INTEGER DEFAULT 0, reply_to_guid TEXT, sort_id INTEGER, is_spam INTEGER DEFAULT 0, has_unseen_mention INTEGER DEFAULT 0, thread_originator_guid TEXT, thread_originator_part TEXT, syndication_ranges TEXT, synced_syndication_ranges TEXT, was_delivered_quietly INTEGER DEFAULT 0, did_notify_recipient INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0, date_edited INTEGER DEFAULT 0, was_detonated INTEGER DEFAULT 0, part_count INTEGER, is_stewie INTEGER DEFAULT 0, is_sos INTEGER DEFAULT 0, is_critical INTEGER DEFAULT 0, bia_reference_id TEXT DEFAULT NULL, is_kt_verified INTEGER DEFAULT 0, fallback_hash TEXT DEFAULT NULL, associated_message_emoji TEXT DEFAULT NULL, is_pending_satellite_send INTEGER DEFAULT 0, needs_relay INTEGER DEFAULT 0, schedule_type INTEGER DEFAULT 0, schedule_state INTEGER DEFAULT 0, sent_or_received_off_grid INTEGER DEFAULT 0, date_recovered INTEGER DEFAULT 0, is_time_sensitive INTEGER DEFAULT 0, ck_chat_id TEXT, index_state INTEGER DEFAULT 0);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER, state INTEGER, account_id TEXT, properties BLOB, chat_identifier TEXT, service_name TEXT, room_name TEXT, account_login TEXT, is_archived INTEGER DEFAULT 0, last_addressed_handle TEXT, display_name TEXT, group_id TEXT, is_filtered INTEGER DEFAULT 0, successful_query INTEGER, engram_id TEXT, server_change_token TEXT, ck_sync_state INTEGER DEFAULT 0, original_group_id TEXT, last_read_message_timestamp INTEGER DEFAULT 0, cloudkit_record_id TEXT, last_addressed_sim_id TEXT, is_blackholed INTEGER DEFAULT 0, syndication_date INTEGER DEFAULT 0, syndication_type INTEGER DEFAULT 0, is_recovered INTEGER DEFAULT 0, is_deleting_incoming_messages INTEGER DEFAULT 0, is_pending_review INTEGER DEFAULT 0);
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, id TEXT NOT NULL, country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT, person_centric_id TEXT, UNIQUE (id, service));
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, created_date INTEGER DEFAULT 0, start_date INTEGER DEFAULT 0, filename TEXT, uti TEXT, mime_type TEXT, transfer_state INTEGER DEFAULT 0, is_outgoing INTEGER DEFAULT 0, user_info BLOB, transfer_name TEXT, total_bytes INTEGER DEFAULT 0, is_sticker INTEGER DEFAULT 0, sticker_user_info BLOB, attribution_info BLOB, hide_attachment INTEGER DEFAULT 0, ck_sync_state INTEGER DEFAULT 0, ck_server_change_token_blob BLOB, ck_record_id TEXT, original_guid TEXT UNIQUE NOT NULL, is_commsafety_sensitive INTEGER DEFAULT 0, emoji_image_content_identifier TEXT DEFAULT NULL, emoji_image_short_description TEXT DEFAULT NULL, preview_generation_state INTEGER DEFAULT 0);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0, index_state INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (chat_id, message_id));
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE(chat_id, handle_id));
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER, UNIQUE(message_id, attachment_id));
"""


def typedstream(text: str) -> bytes:
    """Archive `typedstream` minimale d'un NSAttributedString — en-tête réel,
    chaîne encodée comme Messages l'encode (longueur 1, 2 ou 4 octets)."""
    body = text.encode("utf-8")
    if len(body) < 0x81:
        length = bytes([len(body)])
    elif len(body) <= 0xFFFF:
        length = b"\x81" + struct.pack("<H", len(body))
    else:
        length = b"\x82" + struct.pack("<I", len(body))
    return (
        b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00"
        b"\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+"
        + length
        + body
        + b"\x86\x84\x02iI\x01\x92\x84\x84\x84\x0cNSDictionary\x00\x94\x84\x01i\x00\x86"
    )


def summary_info(versions):
    """`message_summary_info` d'un message modifié : une entrée par version."""
    return plistlib.dumps(
        {
            "amc": 0,
            "ec": {
                "0": [
                    {"d": 700000000.0 + index, "t": typedstream(text)}
                    for index, text in enumerate(versions)
                ]
            },
            "ust": True,
        },
        fmt=plistlib.FMT_BINARY,
    )


def apple_ns(seconds: int) -> int:
    """Secondes depuis 2001 → nanosecondes, comme `message.date` sur macOS 26."""
    return seconds * 1_000_000_000


def main():
    if os.path.exists(DEST):
        os.remove(DEST)
    db = sqlite3.connect(DEST)
    db.executescript(SCHEMA)

    db.executemany(
        "INSERT INTO handle (ROWID, id, service) VALUES (?, ?, 'iMessage')",
        [(1, "+33611111111"), (2, "+33622222222"), (3, "camille@example.com")],
    )

    group_properties = plistlib.dumps(
        {"groupPhotoGuid": "at_0_FIXTURE-PHOTO", "gppv": 5},
        fmt=plistlib.FMT_BINARY,
    )
    db.execute(
        "INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name, properties)"
        " VALUES (1, 'iMessage;-;+33611111111', 45, '+33611111111', 'iMessage', '', NULL)"
    )
    db.execute(
        "INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name, properties)"
        " VALUES (2, 'iMessage;+;chat900000000', 43, 'chat900000000', 'iMessage', 'Les marmottes', ?)",
        (sqlite3.Binary(group_properties),),
    )
    db.executemany(
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)",
        [(1, 1), (2, 1), (2, 2), (2, 3)],
    )

    # Pièces jointes : une photo de groupe, un message audio.
    db.executemany(
        "INSERT INTO attachment (ROWID, guid, original_guid, filename, mime_type, uti, transfer_name)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
            (
                1,
                "at_0_FIXTURE-PHOTO",
                "at_0_FIXTURE-PHOTO",
                "~/Library/Messages/Attachments/ff/00/at_0_FIXTURE-PHOTO/GroupPhotoImage",
                "",
                "public.jpeg",
                "GroupPhotoImage",
            ),
            (
                2,
                "at_0_FIXTURE-AUDIO",
                "at_0_FIXTURE-AUDIO",
                "~/Library/Messages/Attachments/ff/01/at_0_FIXTURE-AUDIO/Audio Message.caf",
                "audio/x-caf",
                "com.apple.coreaudio-format",
                "Audio Message.caf",
            ),
        ],
    )

    base = 700_000_000
    messages = [
        # (rowid, guid, text, date, is_from_me, handle_id, extra colonnes)
        (1, "FIX-0001", "Bonjour", base, 0, 1, {}),
        (
            2,
            "FIX-0002",
            "Version finale",
            base + 60,
            1,
            0,
            {
                "date_edited": apple_ns(base + 90),
                "message_summary_info": sqlite3.Binary(
                    summary_info(["Premier jet", "Version finale"])
                ),
            },
        ),
        (3, "FIX-0003", None, base + 120, 1, 0, {"date_retracted": apple_ns(base + 130)}),
        (
            4,
            "FIX-0004",
            "Bravo !",
            base + 180,
            0,
            1,
            {"expressive_send_style_id": "com.apple.messages.effect.CKConfettiEffect"},
        ),
        (5, "FIX-0005", None, base + 240, 0, 1, {"is_audio_message": 1}),
        # Groupe : trois événements et un message ordinaire.
        (6, "FIX-0006", None, base + 300, 0, 1, {"item_type": 1, "group_action_type": 0, "other_handle": 2}),
        (
            7,
            "FIX-0007",
            None,
            base + 360,
            1,
            0,
            {"item_type": 2, "group_title": "Les marmottes"},
        ),
        (8, "FIX-0008", None, base + 420, 0, 1, {"item_type": 3, "group_action_type": 1}),
        (9, "FIX-0009", "On part quand ?", base + 480, 0, 2, {}),
    ]

    for rowid, guid, text, date, from_me, handle, extra in messages:
        columns = {
            "ROWID": rowid,
            "guid": guid,
            "text": text,
            "date": apple_ns(date),
            "is_from_me": from_me,
            "handle_id": handle,
            "service": "iMessage",
            "is_sent": from_me,
            "is_delivered": from_me,
        }
        columns.update(extra)
        names = ", ".join(columns)
        holes = ", ".join("?" for _ in columns)
        db.execute(f"INSERT INTO message ({names}) VALUES ({holes})", list(columns.values()))

    db.executemany(
        "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)",
        [(1, i, apple_ns(base + i)) for i in range(1, 6)]
        + [(2, i, apple_ns(base + i)) for i in range(6, 10)],
    )
    db.execute("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (5, 2)")

    db.commit()
    db.close()
    print("fixture écrite :", os.path.normpath(DEST))


if __name__ == "__main__":
    main()
