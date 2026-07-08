import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_updater/src/appcast.dart';
import 'package:auto_updater/src/updater_error.dart';
import 'package:auto_updater/src/updater_listener.dart';
import 'package:auto_updater_platform_interface/auto_updater_platform_interface.dart';

class AutoUpdater {
  AutoUpdater._() {
    _platform.sparkleEvents.listen(_handleSparkleEvents);
  }

  /// The shared instance of [AutoUpdater].
  static final AutoUpdater instance = AutoUpdater._();

  AutoUpdaterPlatform get _platform => AutoUpdaterPlatform.instance;

  final List<UpdaterListener> _listeners = [];

  void _handleSparkleEvents(event) {
    print(
        'AutoUpdater Event Received: type=${event['type']}, data=${event['data']}');
    UpdaterError? updaterError;
    Appcast? appcast;
    AppcastItem? appcastItem;

    String type = event['type'] as String;
    Map<Object?, Object?>? data;
    if (event['data'] != null) {
      data = event['data'] as Map;
      if (data['error'] != null) {
        updaterError = UpdaterError(
          data['error'].toString(),
        );
      }
      if (data['appcast'] != null) {
        appcast = Appcast.fromJson(
          Map<String, dynamic>.from(
            (data['appcast'] as Map).cast<String, dynamic>(),
          ),
        );
      }
      if (data['appcastItem'] != null) {
        appcastItem = AppcastItem.fromJson(
          Map<String, dynamic>.from(
            (data['appcastItem'] as Map).cast<String, dynamic>(),
          ),
        );
      }
    }
    for (var listener in _listeners) {
      switch (type) {
        case 'error':
          listener.onUpdaterError(updaterError);
          break;
        case 'checking-for-update':
          listener.onUpdaterCheckingForUpdate(appcast);
          break;
        case 'update-available':
          listener.onUpdaterUpdateAvailable(appcastItem);
          break;
        case 'update-not-available':
          listener.onUpdaterUpdateNotAvailable(updaterError);
          break;
        case 'update-downloaded':
          listener.onUpdaterUpdateDownloaded(appcastItem);
          break;
        case 'before-quit-for-update':
          _proxy?.stop();
          listener.onUpdaterBeforeQuitForUpdate(appcastItem);
          break;
      }
    }
  }

  LocalUpdateProxy? _proxy;

  /// Adds a listener to the auto updater.
  void addListener(UpdaterListener listener) {
    _listeners.add(listener);
  }

  /// Removes a listener from the auto updater.
  void removeListener(UpdaterListener listener) {
    _listeners.remove(listener);
  }

  /// Sets the url and initialize the auto updater.
  Future<void> setFeedURL(String feedUrl) async {
    print('AutoUpdater calling setFeedURL: $feedUrl');
    String finalFeedUrl = feedUrl;
    if (Platform.isWindows && feedUrl.startsWith('http')) {
      try {
        if (_proxy != null) {
          await _proxy!.stop();
          _proxy = null;
        }
        _proxy = LocalUpdateProxy(feedUrl);
        final int port = await _proxy!.start();
        finalFeedUrl = 'http://localhost:$port/feed.xml';
        print(
            'AutoUpdater proxy started on port $port, forwarding to local feed: $finalFeedUrl');
      } catch (e) {
        print('AutoUpdater failed to start proxy: $e');
      }
    }
    return _platform.setFeedURL(finalFeedUrl);
  }

  /// Asks the server whether there is an update. You must call setFeedURL before using this API.
  Future<void> checkForUpdates({bool? inBackground}) {
    print('AutoUpdater calling checkForUpdates: inBackground=$inBackground');
    return _platform.checkForUpdates(
      inBackground: inBackground,
    );
  }

  /// Sets the auto update check interval, default 86400, minimum 3600, 0 to disable update
  Future<void> setScheduledCheckInterval(int interval) {
    return _platform.setScheduledCheckInterval(interval);
  }

  /// Sets custom HTTP headers for appcast checks.
  Future<void> setHttpHeaders(Map<String, String> headers) {
    print('AutoUpdater calling setHttpHeaders: $headers');
    return _platform.setHttpHeaders(headers);
  }
}

final autoUpdater = AutoUpdater.instance;

class LocalUpdateProxy {
  HttpServer? _server;
  final String realXmlUrl;
  String? realExeUrl;
  String? realReleaseNotesUrl;
  final HttpClient _client = HttpClient()
    ..badCertificateCallback =
        ((X509Certificate cert, String host, int port) => true)
    ..connectionTimeout = const Duration(seconds: 10);

  LocalUpdateProxy(this.realXmlUrl);

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest, onError: (e) {
      print('LocalUpdateProxy server error: $e');
    });
    print('LocalUpdateProxy listening on port ${_server!.port}');
    return _server!.port;
  }

  /// Fetches URL with a total timeout (connection + response)
  Future<String?> _fetchUrl(String url, {Duration timeout = const Duration(seconds: 10)}) async {
    try {
      print('LocalUpdateProxy fetching: $url');
      final realUri = Uri.parse(url);
      final clientReq = await _client.getUrl(realUri);
      clientReq.headers.set(
        HttpHeaders.userAgentHeader,
        'WinSparkle/1.0',
      );

      final clientRes = await clientReq.close().timeout(timeout);

      if (clientRes.statusCode != 200) {
        print('LocalUpdateProxy fetch failed: HTTP ${clientRes.statusCode}');
        await clientRes.drain();
        return null;
      }

      final body = await utf8.decoder.bind(clientRes).join().timeout(timeout);
      print('LocalUpdateProxy fetched ${body.length} bytes from $url');
      return body;
    } on TimeoutException {
      print('LocalUpdateProxy TIMEOUT fetching: $url');
      return null;
    } catch (e) {
      print('LocalUpdateProxy ERROR fetching $url: $e');
      return null;
    }
  }

  void _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    print('LocalUpdateProxy received request: $path');

    try {
      if (path == '/feed.xml') {
        await _handleFeedXml(request);
      } else if (path == '/download.exe') {
        await _handleDownloadExe(request);
      } else if (path == '/release_notes.html') {
        // Always return local HTML immediately - no external fetch needed
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.write(
            '<html><body><h3>UniFO Update</h3><p>Phiên bản mới đã sẵn sàng tải về.</p></body></html>');
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      print('LocalUpdateProxy request error ($path): $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleFeedXml(HttpRequest request) async {
    final xmlContent = await _fetchUrl(realXmlUrl);

    if (xmlContent == null || xmlContent.isEmpty) {
      // CRITICAL FIX: Return a valid "no update" XML instead of an error
      // This prevents WinSparkle from showing an error dialog
      print('LocalUpdateProxy: XML fetch failed, returning empty appcast (no update)');
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType =
          ContentType.parse('application/xml; charset=utf-8');
      request.response.write(
          '<?xml version="1.0" encoding="utf-8"?>'
          '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
          '<channel><title>No Update</title></channel></rss>');
      await request.response.close();
      return;
    }

    final myPort = _server!.port;
    var modifiedXml = xmlContent;

    // Parse enclosure URL - target specifically the <enclosure> element's url attribute
    final enclosureMatch =
        RegExp(r'<enclosure[^>]+url="([^"]+)"', caseSensitive: false)
            .firstMatch(xmlContent);
    if (enclosureMatch != null) {
      final originalExeUrl = enclosureMatch.group(1)!;
      realExeUrl =
          Uri.parse(realXmlUrl).resolve(originalExeUrl).toString();
      modifiedXml = modifiedXml.replaceFirst(
        originalExeUrl,
        'http://localhost:$myPort/download.exe',
      );
      print('LocalUpdateProxy: Rewrote enclosure URL: $originalExeUrl -> localhost:$myPort/download.exe');
    } else {
      print('LocalUpdateProxy WARNING: No <enclosure url="..."> found in XML');
    }

    // Parse release notes URL
    final notesMatch = RegExp(
            r'<(?:[a-zA-Z0-9_-]+:)?releaseNotesLink>([^<]+)</(?:[a-zA-Z0-9_-]+:)?releaseNotesLink>',
            caseSensitive: false)
        .firstMatch(xmlContent);
    if (notesMatch != null) {
      final originalNotesUrl = notesMatch.group(1)!.trim();
      realReleaseNotesUrl = originalNotesUrl;
      modifiedXml = modifiedXml.replaceFirst(
        originalNotesUrl,
        'http://localhost:$myPort/release_notes.html',
      );
      print('LocalUpdateProxy: Rewrote release notes URL: $originalNotesUrl -> localhost:$myPort/release_notes.html');
    }

    // Log final XML for debugging
    print('LocalUpdateProxy: Serving modified XML (${modifiedXml.length} bytes)');

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType.parse('application/xml; charset=utf-8');
    request.response.write(modifiedXml);
    await request.response.close();
  }

  Future<void> _handleDownloadExe(HttpRequest request) async {
    if (realExeUrl == null) {
      print('LocalUpdateProxy: No download URL available');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      print('LocalUpdateProxy: Proxying download from $realExeUrl');
      final realUri = Uri.parse(realExeUrl!);
      final clientReq = await _client.getUrl(realUri);
      clientReq.headers.set(
        HttpHeaders.userAgentHeader,
        'WinSparkle/1.0',
      );

      final clientRes = await clientReq.close().timeout(
          const Duration(seconds: 10));

      request.response.statusCode = clientRes.statusCode;
      // Only copy content-related headers
      if (clientRes.headers.contentType != null) {
        request.response.headers.contentType = clientRes.headers.contentType!;
      }
      final contentLength = clientRes.headers.value(HttpHeaders.contentLengthHeader);
      if (contentLength != null) {
        request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength);
      }

      await request.response.addStream(clientRes);
      await request.response.close();
      print('LocalUpdateProxy: Download proxy completed');
    } catch (e) {
      print('LocalUpdateProxy: Download proxy error: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    print('LocalUpdateProxy stopped');
  }
}
