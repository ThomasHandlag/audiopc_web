import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

final class MetaDataExtractor {
  Uint8List? extractCoverArt(Uint8List bytes) {
    // Verify the ID3v2 tag identifier
    if (bytes.length < 10 ||
        bytes[0] != 0x49 || // 'I'
        bytes[1] != 0x44 || // 'D'
        bytes[2] != 0x33) {
      // '3'
      return null;
    }

    // Calculate total tag size (4 bytes syncsafe integer)
    int tagSize =
        ((bytes[6] & 0x7F) << 21) |
        ((bytes[7] & 0x7F) << 14) |
        ((bytes[8] & 0x7F) << 7) |
        (bytes[9] & 0x7F);

    int offset = 10; // Past the 10-byte ID3 header
    int endOfTag = offset + tagSize;

    // Search through all frames
    while (offset < endOfTag && offset + 10 < bytes.length) {
      String frameId = String.fromCharCodes(bytes.sublist(offset, offset + 4));

      // Frame size (4 bytes integer)
      int frameSize =
          (bytes[offset + 4] << 24) |
          (bytes[offset + 5] << 16) |
          (bytes[offset + 6] << 8) |
          bytes[offset + 7];

      offset += 10; // Skip the frame header

      if (frameId == "APIC") {
        return _parseApicData(bytes.sublist(offset, offset + frameSize));
      }

      offset += frameSize; // Move to next frame
    }

    return null;
  }

  /// Parses raw APIC frame payload to isolate the core image binary bytes.
  Uint8List? _parseApicData(Uint8List apicBytes) {
    if (apicBytes.isEmpty) return null;

    int offset = 0;

    // 1. Text encoding byte
    int encoding = apicBytes[offset];
    offset += 1;

    // 2. MIME type string (terminated by 0x00)
    int mimeEnd = apicBytes.indexOf(0, offset);
    if (mimeEnd == -1) return null;
    offset = mimeEnd + 1;

    // 3. Picture type byte
    offset += 1;

    // 4. Description string (terminated by 0x00 or 0x00 0x00 depending on encoding)
    if (encoding == 1 || encoding == 2) {
      // UTF-16 strings end with two null bytes
      while (offset < apicBytes.length - 1) {
        if (apicBytes[offset] == 0 && apicBytes[offset + 1] == 0) {
          offset += 2;
          break;
        }
        offset++;
      }
    } else {
      // UTF-8 or ISO-8859-1 end with one null byte
      int descEnd = apicBytes.indexOf(0, offset);
      if (descEnd != -1) offset = descEnd + 1;
    }

    // 5. The remaining bytes are the raw image file (JPEG, PNG, etc.)
    return apicBytes.sublist(offset);
  }

  Future<Map<String, String>?> getMetadata(String uri) async {
    try {
      final response = await window.fetch(uri.toJS).toDart;
      if (!response.ok) return null;

      final jsBuffer = await response.arrayBuffer().toDart;
      final dartBuffer = jsBuffer.toDart;
      final bytes = Uint8List.view(dartBuffer);

      return _parseId3v2Tags(bytes);
    } catch (e) {
      print('Error getting metadata: $e');
      return null;
    }
  }

  Map<String, String>? _parseId3v2Tags(Uint8List bytes) {
    // Check for 'ID3' magic number
    if (bytes.length < 10 ||
        bytes[0] != 0x49 ||
        bytes[1] != 0x44 ||
        bytes[2] != 0x33) {
      return null;
    }

    // Calculate total tag size
    int tagSize =
        ((bytes[6] & 0x7F) << 21) |
        ((bytes[7] & 0x7F) << 14) |
        ((bytes[8] & 0x7F) << 7) |
        (bytes[9] & 0x7F);

    int offset = 10;
    int endOfTag = offset + tagSize;

    final Map<String, String> metadata = {};

    while (offset < endOfTag && offset + 10 < bytes.length) {
      String frameId = String.fromCharCodes(bytes.sublist(offset, offset + 4));

      int frameSize =
          (bytes[offset + 4] << 24) |
          (bytes[offset + 5] << 16) |
          (bytes[offset + 6] << 8) |
          bytes[offset + 7];

      offset += 10; // Skip frame header

      if (frameSize <= 0 || offset + frameSize > bytes.length) break;

      Uint8List frameData = bytes.sublist(offset, offset + frameSize);

      // Map frame IDs to friendly keys
      switch (frameId) {
        case 'TIT2':
          metadata['title'] = _parseTextFrame(frameData);
          break;
        case 'TPE1':
          metadata['artist'] = _parseTextFrame(frameData);
          break;
        case 'TALB':
          metadata['album'] = _parseTextFrame(frameData);
          break;
      }

      offset += frameSize;
    }

    return metadata;
  }

  /// Parses the payload of a text frame based on its encoding byte.
  String _parseTextFrame(Uint8List frameData) {
    if (frameData.isEmpty) return '';

    int encoding = frameData[0];
    Uint8List textBytes = frameData.sublist(1);

    if (textBytes.isEmpty) return '';

    if (encoding == 1 || encoding == 2) {
      // UTF-16 encoding
      return _decodeUtf16(textBytes);
    } else {
      // ISO-8859-1 or UTF-8
      return String.fromCharCodes(
        textBytes,
      ).trim().replaceAll(RegExp(r'\x00+$'), '');
    }
  }

  /// A basic UTF-16 decoder for strings containing a Byte Order Mark (BOM)
  String _decodeUtf16(Uint8List bytes) {
    if (bytes.length < 2) return '';

    bool isLittleEndian = false;
    int start = 0;

    // Check for BOM
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      isLittleEndian = true;
      start = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      isLittleEndian = false;
      start = 2;
    }

    List<int> codeUnits = [];
    for (int i = start; i < bytes.length - 1; i += 2) {
      int charCode = isLittleEndian
          ? (bytes[i + 1] << 8) | bytes[i]
          : (bytes[i] << 8) | bytes[i + 1];

      if (charCode != 0) codeUnits.add(charCode);
    }

    return String.fromCharCodes(codeUnits).trim();
  }
}
