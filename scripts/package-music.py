#!/usr/bin/env python3
"""Build and install the server's custom OpenRCT2 ride-music object."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import NamedTuple
import wave
import zipfile


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE_DIR = ROOT_DIR / "data" / "music" / "source"
DEFAULT_OBJECT_DIR = ROOT_DIR / "data" / "object"
DEFAULT_PLUGIN_FILE = ROOT_DIR / "data" / "plugin" / "b5-custom-music.js"
DEFAULT_STATE_FILE = ROOT_DIR / "data" / "music" / "current-object.txt"

OBJECT_PREFIX = "b5.music.ultimate_fun_land."
SAMPLE_RATE = 27_560
CHANNELS = 1
SAMPLE_WIDTH = 2
BYTES_PER_TICK = 1_378
STREAM_MIN_BYTES = 2 * 1024 * 1024
MAX_TOTAL_PCM_BYTES = 256 * 1024 * 1024
OGG_QUALITY = 3
OGG_CAPTURE_PATTERN = b"OggS"
OGG_NO_GRANULE = (1 << 64) - 1
OGG_CRC_POLYNOMIAL = 0x04C11DB7
OGG_PADDING_KEY = b"B5PADDING="
SUPPORTED_EXTENSIONS = {
    ".aac",
    ".aif",
    ".aiff",
    ".flac",
    ".m4a",
    ".mp3",
    ".ogg",
    ".opus",
    ".wav",
}


class PackagingError(RuntimeError):
    pass


class OggPage(NamedTuple):
    header_type: int
    granule_position: int
    serial: int
    sequence: int
    segments: bytes
    body: bytes


def build_ogg_crc_table() -> tuple[int, ...]:
    table = []
    for value in range(256):
        remainder = value << 24
        for _ in range(8):
            remainder = (
                ((remainder << 1) ^ OGG_CRC_POLYNOMIAL)
                if remainder & 0x80000000
                else remainder << 1
            ) & 0xFFFFFFFF
        table.append(remainder)
    return tuple(table)


OGG_CRC_TABLE = build_ogg_crc_table()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Convert data/music/source tracks and install a multiplayer-safe "
            "OpenRCT2 music object."
        )
    )
    parser.add_argument("--name", default="Ultimate Fun Land Radio", help="music style name")
    parser.add_argument("--author", default="B5", help="object author")
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE_DIR)
    parser.add_argument("--object-dir", type=Path, default=DEFAULT_OBJECT_DIR)
    parser.add_argument("--plugin-file", type=Path, default=DEFAULT_PLUGIN_FILE)
    parser.add_argument("--state-file", type=Path, default=DEFAULT_STATE_FILE)
    return parser.parse_args()


def discover_sources(source_dir: Path) -> list[Path]:
    source_dir.mkdir(parents=True, exist_ok=True)
    sources = sorted(
        (
            path
            for path in source_dir.iterdir()
            if path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS
        ),
        key=lambda path: path.name.casefold(),
    )
    if not sources:
        extensions = ", ".join(sorted(SUPPORTED_EXTENSIONS))
        raise PackagingError(
            f"No audio files found in {source_dir}. Supported extensions: {extensions}"
        )
    if len(sources) > 255:
        raise PackagingError("OpenRCT2 music objects support at most 255 tracks.")
    return sources


def read_canonical_wav(path: Path) -> bytes | None:
    try:
        with wave.open(str(path), "rb") as source:
            if (
                source.getcomptype() != "NONE"
                or source.getnchannels() != CHANNELS
                or source.getsampwidth() != SAMPLE_WIDTH
                or source.getframerate() != SAMPLE_RATE
            ):
                return None
            return source.readframes(source.getnframes())
    except (EOFError, wave.Error):
        return None


def convert_with_ffmpeg(path: Path, temporary_dir: Path, ffmpeg: str) -> bytes:
    raw_path = temporary_dir / f"{path.stem}.raw"
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(path),
        "-map",
        "0:a:0",
        "-map_metadata",
        "-1",
        "-vn",
        "-ac",
        str(CHANNELS),
        "-ar",
        str(SAMPLE_RATE),
        "-c:a",
        "pcm_s16le",
        "-f",
        "s16le",
        str(raw_path),
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or f"ffmpeg exited with status {result.returncode}"
        raise PackagingError(f"Could not convert {path.name}: {detail}")
    return raw_path.read_bytes()


def prepare_pcm(path: Path, temporary_dir: Path, ffmpeg: str | None) -> bytes:
    pcm = read_canonical_wav(path) if path.suffix.lower() == ".wav" else None
    if pcm is None:
        if ffmpeg is None:
            raise PackagingError(
                f"{path.name} needs conversion, but ffmpeg is not installed. "
                "Install ffmpeg or supply mono 16-bit PCM WAV at 27560 Hz."
            )
        pcm = convert_with_ffmpeg(path, temporary_dir, ffmpeg)

    if not pcm or len(pcm) % (CHANNELS * SAMPLE_WIDTH) != 0:
        raise PackagingError(f"{path.name} did not produce valid 16-bit mono PCM audio.")

    padding = (2 - (len(pcm) % BYTES_PER_TICK)) % BYTES_PER_TICK
    if padding:
        pcm += bytes(padding)

    if len(pcm) < STREAM_MIN_BYTES:
        duration = len(pcm) / (SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH)
        raise PackagingError(
            f"{path.name} is only {duration:.1f} seconds after conversion; tracks must be "
            "at least 39 seconds to stay synchronized between the headless server and clients."
        )
    return pcm


def parse_ogg_pages(encoded: bytes, name: str) -> list[OggPage]:
    pages = []
    offset = 0
    while offset < len(encoded):
        if offset + 27 > len(encoded) or encoded[offset : offset + 4] != OGG_CAPTURE_PATTERN:
            raise PackagingError(f"ffmpeg produced an invalid OGG stream for {name}.")
        if encoded[offset + 4] != 0:
            raise PackagingError(f"ffmpeg produced an unsupported OGG version for {name}.")

        segment_count = encoded[offset + 26]
        segment_table_end = offset + 27 + segment_count
        if segment_table_end > len(encoded):
            raise PackagingError(f"ffmpeg produced a truncated OGG page for {name}.")
        segments = encoded[offset + 27 : segment_table_end]
        body_end = segment_table_end + sum(segments)
        if body_end > len(encoded):
            raise PackagingError(f"ffmpeg produced a truncated OGG page for {name}.")

        pages.append(
            OggPage(
                encoded[offset + 5],
                struct.unpack_from("<Q", encoded, offset + 6)[0],
                struct.unpack_from("<I", encoded, offset + 14)[0],
                struct.unpack_from("<I", encoded, offset + 18)[0],
                segments,
                encoded[segment_table_end:body_end],
            )
        )
        offset = body_end
    return pages


def split_ogg_headers(encoded: bytes, name: str) -> tuple[list[bytes], list[OggPage]]:
    pages = parse_ogg_pages(encoded, name)
    packets: list[bytes] = []
    packet = bytearray()

    for page_index, page in enumerate(pages):
        body_offset = 0
        for segment_index, segment_size in enumerate(page.segments):
            body_end = body_offset + segment_size
            packet.extend(page.body[body_offset:body_end])
            body_offset = body_end
            if segment_size < 255:
                packets.append(bytes(packet))
                packet.clear()
                if len(packets) == 3:
                    suffix = []
                    remaining_segments = page.segments[segment_index + 1 :]
                    if remaining_segments:
                        suffix.append(
                            OggPage(
                                page.header_type & ~0x03,
                                page.granule_position,
                                page.serial,
                                page.sequence,
                                remaining_segments,
                                page.body[body_offset:],
                            )
                        )
                    suffix.extend(pages[page_index + 1 :])
                    return packets, suffix

    raise PackagingError(f"ffmpeg omitted Vorbis headers for {name}.")


def add_vorbis_padding(comment: bytes, padding_size: int, name: str) -> bytes:
    if not comment.startswith(b"\x03vorbis"):
        raise PackagingError(f"ffmpeg produced an invalid Vorbis comment for {name}.")

    offset = 7
    if offset + 4 > len(comment):
        raise PackagingError(f"ffmpeg produced a truncated Vorbis comment for {name}.")
    vendor_size = struct.unpack_from("<I", comment, offset)[0]
    offset += 4 + vendor_size
    if offset + 4 > len(comment):
        raise PackagingError(f"ffmpeg produced a truncated Vorbis comment for {name}.")

    count_offset = offset
    comment_count = struct.unpack_from("<I", comment, offset)[0]
    offset += 4
    records_offset = offset
    for _ in range(comment_count):
        if offset + 4 > len(comment):
            raise PackagingError(f"ffmpeg produced a truncated Vorbis comment for {name}.")
        item_size = struct.unpack_from("<I", comment, offset)[0]
        offset += 4 + item_size
        if offset > len(comment):
            raise PackagingError(f"ffmpeg produced a truncated Vorbis comment for {name}.")

    if offset + 1 != len(comment) or comment[offset] != 1:
        raise PackagingError(f"ffmpeg produced an invalid Vorbis comment framing bit for {name}.")

    padding = OGG_PADDING_KEY + (b" " * padding_size)
    return b"".join(
        (
            comment[:count_offset],
            struct.pack("<I", comment_count + 1),
            comment[records_offset:offset],
            struct.pack("<I", len(padding)),
            padding,
            b"\x01",
        )
    )


def ogg_packet_storage_size(packet_size: int) -> int:
    segment_count = (packet_size // 255) + 1
    page_count = (segment_count + 254) // 255
    return packet_size + segment_count + (page_count * 27)


def ogg_crc(data: bytearray) -> int:
    checksum = 0
    for value in data:
        checksum = ((checksum << 8) & 0xFFFFFFFF) ^ OGG_CRC_TABLE[
            ((checksum >> 24) & 0xFF) ^ value
        ]
    return checksum


def serialise_ogg_page(page: OggPage, sequence: int) -> bytes:
    header = bytearray(27 + len(page.segments))
    header[:4] = OGG_CAPTURE_PATTERN
    header[4] = 0
    header[5] = page.header_type
    struct.pack_into("<Q", header, 6, page.granule_position)
    struct.pack_into("<I", header, 14, page.serial)
    struct.pack_into("<I", header, 18, sequence)
    header[26] = len(page.segments)
    header[27:] = page.segments
    complete_page = header + page.body
    struct.pack_into("<I", complete_page, 22, ogg_crc(complete_page))
    return bytes(complete_page)


def serialise_ogg_packet(packet: bytes, serial: int, sequence: int) -> tuple[bytes, int]:
    remainder = len(packet) % 255
    lacing = (b"\xff" * (len(packet) // 255)) + bytes((remainder,))
    output = bytearray()
    packet_offset = 0
    page_index = 0
    for segment_offset in range(0, len(lacing), 255):
        segments = lacing[segment_offset : segment_offset + 255]
        body_size = sum(segments)
        body = packet[packet_offset : packet_offset + body_size]
        packet_offset += body_size
        is_final_page = segment_offset + len(segments) == len(lacing)
        header_type = 0
        if sequence == 0:
            header_type |= 0x02
        if page_index > 0:
            header_type |= 0x01
        page = OggPage(
            header_type,
            0 if is_final_page else OGG_NO_GRANULE,
            serial,
            sequence,
            segments,
            body,
        )
        output.extend(serialise_ogg_page(page, sequence))
        sequence += 1
        page_index += 1
    return bytes(output), sequence


def pad_ogg_to_pcm_size(encoded: bytes, pcm_size: int, name: str) -> bytes:
    headers, suffix = split_ogg_headers(encoded, name)
    identification, comment, setup = headers
    if not identification.startswith(b"\x01vorbis") or not setup.startswith(b"\x05vorbis"):
        raise PackagingError(f"ffmpeg produced invalid Vorbis headers for {name}.")
    if len(identification) < 16:
        raise PackagingError(f"ffmpeg produced a truncated Vorbis identification for {name}.")

    channels = identification[11]
    sample_rate = struct.unpack_from("<I", identification, 12)[0]
    eos_pages = [page for page in suffix if page.header_type & 0x04]
    if not eos_pages:
        raise PackagingError(f"ffmpeg omitted the OGG end-of-stream page for {name}.")
    decoded_size = eos_pages[-1].granule_position * channels * SAMPLE_WIDTH
    if sample_rate != SAMPLE_RATE or channels != CHANNELS or decoded_size != pcm_size:
        raise PackagingError(f"ffmpeg produced unexpected Vorbis audio properties for {name}.")

    suffix_size = sum(27 + len(page.segments) + len(page.body) for page in suffix)

    def output_size(padding_size: int) -> int:
        padded_comment_size = len(comment) + 4 + len(OGG_PADDING_KEY) + padding_size
        return (
            ogg_packet_storage_size(len(identification))
            + ogg_packet_storage_size(padded_comment_size)
            + ogg_packet_storage_size(len(setup))
            + suffix_size
        )

    if output_size(0) > pcm_size:
        raise PackagingError(f"Vorbis output for {name} cannot be padded to its decoded PCM size.")

    low = 0
    high = pcm_size
    while low < high:
        middle = (low + high + 1) // 2
        if output_size(middle) <= pcm_size:
            low = middle
        else:
            high = middle - 1

    padded_headers = [identification, add_vorbis_padding(comment, low, name), setup]
    serial = suffix[0].serial if suffix else 0
    result = bytearray()
    sequence = 0
    for packet in padded_headers:
        packet_data, sequence = serialise_ogg_packet(packet, serial, sequence)
        result.extend(packet_data)
    for page in suffix:
        if page.serial != serial:
            raise PackagingError(f"Chained OGG streams are not supported for {name}.")
        result.extend(serialise_ogg_page(page, sequence))
        sequence += 1

    result.extend(bytes(pcm_size - len(result)))
    if len(result) != pcm_size:
        raise PackagingError(f"Vorbis padding produced the wrong size for {name}.")
    return bytes(result)


def write_ogg(path: Path, pcm: bytes, ffmpeg: str) -> None:
    raw_path = path.with_suffix(".raw")
    raw_path.write_bytes(pcm)
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-f",
        "s16le",
        "-ar",
        str(SAMPLE_RATE),
        "-ac",
        str(CHANNELS),
        "-i",
        str(raw_path),
        "-map_metadata",
        "-1",
        "-c:a",
        "libvorbis",
        "-q:a",
        str(OGG_QUALITY),
        str(path),
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or f"ffmpeg exited with status {result.returncode}"
        raise PackagingError(f"Could not encode {path.name}: {detail}")
    path.write_bytes(pad_ogg_to_pcm_size(path.read_bytes(), len(pcm), path.name))


def track_title(path: Path) -> str:
    return re.sub(r"\s+", " ", path.stem.replace("_", " ")).strip()


def track_filename(index: int, title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.casefold()).strip("-")[:48]
    return f"tracks/{index:03d}-{slug or 'track'}.ogg"


def write_atomic_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as temporary:
            temporary.write(content)
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def build_plugin(identifier: str) -> str:
    identifier_json = json.dumps(identifier)
    prefix_json = json.dumps(OBJECT_PREFIX)
    return f"""const MUSIC_OBJECT_ID = {identifier_json};
const MUSIC_OBJECT_PREFIX = {prefix_json};

function main() {{
    const loadedMusic = objectManager.getAllObjects("music");
    let musicObject = loadedMusic.find((object) => object.identifier === MUSIC_OBJECT_ID);

    if (musicObject === undefined) {{
        const previousObject = loadedMusic.find(
            (object) => object.identifier.startsWith(MUSIC_OBJECT_PREFIX)
        );
        musicObject = previousObject === undefined
            ? objectManager.load(MUSIC_OBJECT_ID)
            : objectManager.load(MUSIC_OBJECT_ID, previousObject.index);
    }}

    if (musicObject === null || musicObject === undefined) {{
        console.log(`[B5 Custom Music] Failed to load ${{MUSIC_OBJECT_ID}}.`);
        return;
    }}
    console.log(`[B5 Custom Music] Loaded ${{MUSIC_OBJECT_ID}} in music slot ${{musicObject.index}}.`);
}}

registerPlugin({{
    name: "B5 Custom Music Loader",
    version: "1.0.0",
    authors: ["B5"],
    type: "local",
    licence: "MIT",
    minApiVersion: 122,
    targetApiVersion: 122,
    main,
}});
"""


def main() -> int:
    args = parse_args()
    sources = discover_sources(args.source_dir)
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise PackagingError("ffmpeg is required to build the compressed music object.")
    digest = hashlib.sha256()
    digest.update(b"b5-openrct2-music-v3\0")
    digest.update(args.name.encode("utf-8"))
    digest.update(b"\0")
    digest.update(args.author.encode("utf-8"))
    tracks: list[tuple[str, str, Path]] = []
    total_pcm_bytes = 0

    with tempfile.TemporaryDirectory(prefix="openrct2-music-") as temporary_name:
        temporary_dir = Path(temporary_name)
        for index, source in enumerate(sources, start=1):
            title = track_title(source)
            pcm = prepare_pcm(source, temporary_dir, ffmpeg)
            total_pcm_bytes += len(pcm)
            if total_pcm_bytes > MAX_TOTAL_PCM_BYTES:
                raise PackagingError(
                    "Converted tracks exceed the 256 MiB safety limit for the server's "
                    "512 MiB validation filesystem."
                )
            internal_path = track_filename(index, title)
            digest.update(title.encode("utf-8"))
            digest.update(b"\0")
            digest.update(struct.pack("<Q", len(pcm)))
            digest.update(pcm)
            encoded_path = temporary_dir / Path(internal_path).name
            write_ogg(encoded_path, pcm, ffmpeg)
            tracks.append((title, internal_path, encoded_path))

        content_hash = digest.hexdigest()[:16]
        identifier = f"{OBJECT_PREFIX}{content_hash}"
        display_name = f"{args.name} [{content_hash[:8]}]"
        object_definition = {
            "id": identifier,
            "authors": [args.author],
            "version": "1.0",
            "objectType": "music",
            "properties": {
                "niceFactor": 1,
                    "tracks": [
                        {"source": internal_path, "name": title}
                        for title, internal_path, _ in tracks
                ],
            },
            "strings": {"name": {"en-GB": display_name}},
        }

        args.object_dir.mkdir(parents=True, exist_ok=True)
        output_file = args.object_dir / f"{identifier}.parkobj"
        descriptor, temporary_package_name = tempfile.mkstemp(
            prefix=f".{identifier}.", suffix=".parkobj", dir=args.object_dir
        )
        os.close(descriptor)
        try:
            with zipfile.ZipFile(
                temporary_package_name,
                "w",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=9,
            ) as package:
                package.writestr(
                    "object.json",
                    json.dumps(object_definition, ensure_ascii=False, indent=4) + "\n",
                )
                for _, internal_path, encoded_path in tracks:
                    package.write(encoded_path, internal_path, compress_type=zipfile.ZIP_STORED)
            os.chmod(temporary_package_name, 0o600)
            os.replace(temporary_package_name, output_file)
        except BaseException:
            try:
                os.unlink(temporary_package_name)
            except FileNotFoundError:
                pass
            raise

    write_atomic_text(args.plugin_file, build_plugin(identifier))
    write_atomic_text(args.state_file, f"{identifier}\n")

    print(f"Music object: {identifier}")
    print(f"Tracks: {len(tracks)}")
    print(f"Installed: {output_file}")
    print(f"Loader: {args.plugin_file}")
    print("Apply it with: ./scripts/update.sh")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PackagingError as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1)
