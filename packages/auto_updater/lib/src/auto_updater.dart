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
    print('AutoUpdater Event Received: type=${event['type']}, data=${event['data']}');
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
        print('AutoUpdater proxy started on port $port, forwarding to local feed: $finalFeedUrl');
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
  final HttpClient _client = HttpClient()
    ..badCertificateCallback = ((X509Certificate cert, String host, int port) => true)
    ..connectionTimeout = const Duration(seconds: 15);

  LocalUpdateProxy(this.realXmlUrl);

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest, onError: (e) {
      print('Proxy server error: $e');
    });
    return _server!.port;
  }

  void _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/feed.xml') {
        final realUri = Uri.parse(realXmlUrl);
        final clientReq = await _client.getUrl(realUri);
        
        // Copy headers from original request if any
        request.headers.forEach((name, values) {
          if (name.toLowerCase() != 'host' && name.toLowerCase() != 'connection') {
            for (var val in values) {
              clientReq.headers.add(name, val);
            }
          }
        });

        final clientRes = await clientReq.close();
        
        if (clientRes.statusCode != 200) {
          request.response.statusCode = clientRes.statusCode;
          await request.response.close();
          return;
        }

        final xmlContent = await utf8.decoder.bind(clientRes).join();
        
        // Parse the enclosure url from XML
        final match = RegExp(r'url="([^"]+)"').firstMatch(xmlContent);
        if (match != null) {
          final extractedUrl = match.group(1)!;
          realExeUrl = Uri.parse(realXmlUrl).resolve(extractedUrl).toString();
          print('Proxy found and resolved real exe URL: $realExeUrl');
        }

        // Rewrite url in enclosure to point to our local server
        final myPort = _server!.port;
        var modifiedXml = xmlContent;
        if (realExeUrl != null) {
          modifiedXml = xmlContent.replaceAll(
            match!.group(1)!,
            'http://localhost:$myPort/download.exe',
          );
        }

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.parse('application/xml; charset=utf-8');
        request.response.write(modifiedXml);
        await request.response.close();
      } else if (path == '/download.exe') {
        if (realExeUrl == null) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }

        final realUri = Uri.parse(realExeUrl!);
        final clientReq = await _client.getUrl(realUri);
        
        // Copy headers
        request.headers.forEach((name, values) {
          if (name.toLowerCase() != 'host' && name.toLowerCase() != 'connection') {
            for (var val in values) {
              clientReq.headers.add(name, val);
            }
          }
        });

        final clientRes = await clientReq.close();
        
        request.response.statusCode = clientRes.statusCode;
        // Copy response headers
        clientRes.headers.forEach((name, values) {
          for (var val in values) {
            request.response.headers.add(name, val);
          }
        });

        await request.response.addStream(clientRes);
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      print('Proxy request handling error: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}
