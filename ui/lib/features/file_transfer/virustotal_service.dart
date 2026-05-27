import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

enum VtScanStatus { none, scanning, uploading, clean, suspicious, malicious, error }

class VtScanResult {
  const VtScanResult({
    required this.status,
    this.malicious = 0,
    this.suspicious = 0,
    this.totalEngines = 0,
    this.permalink,
    this.errorMessage,
  });

  final VtScanStatus status;
  final int malicious;
  final int suspicious;
  final int totalEngines;
  final String? permalink;
  final String? errorMessage;

  factory VtScanResult.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']?.toString()) {
      'clean' => VtScanStatus.clean,
      'suspicious' => VtScanStatus.suspicious,
      'malicious' => VtScanStatus.malicious,
      'error' => VtScanStatus.error,
      _ => VtScanStatus.none,
    };
    return VtScanResult(
      status: status,
      malicious: (json['malicious'] as num?)?.toInt() ?? 0,
      suspicious: (json['suspicious'] as num?)?.toInt() ?? 0,
      totalEngines: (json['totalEngines'] as num?)?.toInt() ?? 0,
      permalink: json['permalink']?.toString(),
      errorMessage: json['errorMessage']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'malicious': malicious,
    'suspicious': suspicious,
    'totalEngines': totalEngines,
    if (permalink != null) 'permalink': permalink,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };
}

class VirusTotalService {
  static const _baseUrl = 'https://www.virustotal.com/api/v3';
  static const _maxPollAttempts = 20;
  static const _pollInterval = Duration(seconds: 15);

  static Future<String> _sha256OfFile(String path) async {
    late Digest result;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink.withCallback(
        (List<Digest> values) => result = values.single,
      ),
    );
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
    return result.toString();
  }

  static Future<VtScanResult> scan(
    String filePath,
    String apiKey, {
    void Function(VtScanStatus)? onStatus,
  }) async {
    final hash = await _sha256OfFile(filePath);

    final lookupResp = await http.get(
      Uri.parse('$_baseUrl/files/$hash'),
      headers: {'x-apikey': apiKey},
    );

    if (lookupResp.statusCode == 200) {
      return _parseFileReport(
        jsonDecode(lookupResp.body) as Map<String, dynamic>,
        hash,
      );
    }
    if (lookupResp.statusCode != 404) {
      final body = jsonDecode(lookupResp.body) as Map<String, dynamic>?;
      final msg =
          body?['error']?['message']?.toString() ?? '${lookupResp.statusCode}';
      throw Exception(msg);
    }

    // File unknown — upload it
    onStatus?.call(VtScanStatus.uploading);
    final fileSize = await File(filePath).length();
    String uploadUrl = '$_baseUrl/files';
    if (fileSize > 32 * 1024 * 1024) {
      final urlResp = await http.get(
        Uri.parse('$_baseUrl/files/upload_url'),
        headers: {'x-apikey': apiKey},
      );
      if (urlResp.statusCode == 200) {
        uploadUrl =
            (jsonDecode(urlResp.body) as Map<String, dynamic>)['data']
                ?.toString() ??
            uploadUrl;
      }
    }

    final req =
        http.MultipartRequest('POST', Uri.parse(uploadUrl))
          ..headers['x-apikey'] = apiKey
          ..files.add(await http.MultipartFile.fromPath('file', filePath));

    final streamed = await req.send();
    final uploadBody = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      final bodyMap = jsonDecode(uploadBody) as Map<String, dynamic>?;
      final msg =
          bodyMap?['error']?['message']?.toString() ??
          '${streamed.statusCode}';
      throw Exception(msg);
    }

    final analysisId =
        (jsonDecode(uploadBody) as Map<String, dynamic>)['data']?['id']
            ?.toString();
    if (analysisId == null) throw Exception('No analysis ID returned');

    for (var i = 0; i < _maxPollAttempts; i++) {
      await Future.delayed(_pollInterval);

      final pollResp = await http.get(
        Uri.parse('$_baseUrl/analyses/$analysisId'),
        headers: {'x-apikey': apiKey},
      );
      if (pollResp.statusCode != 200) continue;

      final pollData = jsonDecode(pollResp.body) as Map<String, dynamic>;
      final attrs =
          pollData['data']?['attributes'] as Map<String, dynamic>? ?? {};
      if (attrs['status']?.toString() != 'completed') continue;

      final finalResp = await http.get(
        Uri.parse('$_baseUrl/files/$hash'),
        headers: {'x-apikey': apiKey},
      );
      if (finalResp.statusCode == 200) {
        return _parseFileReport(
          jsonDecode(finalResp.body) as Map<String, dynamic>,
          hash,
        );
      }
      return _parseStats(
        attrs['stats'] as Map<String, dynamic>? ?? {},
        hash,
      );
    }

    throw Exception(
      'Analysis timed out after ${_maxPollAttempts * _pollInterval.inSeconds}s',
    );
  }

  static VtScanResult _parseFileReport(
    Map<String, dynamic> body,
    String hash,
  ) {
    final stats =
        body['data']?['attributes']?['last_analysis_stats']
            as Map<String, dynamic>? ??
        {};
    return _parseStats(stats, hash);
  }

  static VtScanResult _parseStats(
    Map<String, dynamic> stats,
    String hash,
  ) {
    final malicious = (stats['malicious'] as num?)?.toInt() ?? 0;
    final suspicious = (stats['suspicious'] as num?)?.toInt() ?? 0;
    final harmless = (stats['harmless'] as num?)?.toInt() ?? 0;
    final undetected = (stats['undetected'] as num?)?.toInt() ?? 0;
    final total = malicious + suspicious + harmless + undetected;
    return VtScanResult(
      status: malicious > 0
          ? VtScanStatus.malicious
          : suspicious > 0
          ? VtScanStatus.suspicious
          : VtScanStatus.clean,
      malicious: malicious,
      suspicious: suspicious,
      totalEngines: total,
      permalink: 'https://www.virustotal.com/gui/file/$hash',
    );
  }
}

