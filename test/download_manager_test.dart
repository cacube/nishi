import 'dart:async';
import 'dart:io';

import 'package:dev_environment_manager/src/download/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory destinationDirectory;
  late HttpServer server;

  setUp(() async {
    destinationDirectory = await Directory.systemTemp.createTemp(
      'download_manager_test_',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    await destinationDirectory.delete(recursive: true);
  });

  test('downloads to the caller directory and reports progress', () async {
    String? acceptEncoding;
    server.listen((request) async {
      acceptEncoding = request.headers.value(HttpHeaders.acceptEncodingHeader);
      request.response.contentLength = 5;
      request.response.add([104, 101, 108, 108, 111]);
      await request.response.close();
    });
    final progress = <DownloadProgress>[];
    final manager = DownloadManager();

    final result = await manager.download(
      source: _serverUri(server),
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      onProgress: progress.add,
    );

    expect(await result.file.readAsString(), 'hello');
    expect(result.fromCache, isFalse);
    expect(File('${result.file.path}.part').existsSync(), isFalse);
    expect(progress, isNotEmpty);
    expect(progress.last.downloadedBytes, 5);
    expect(progress.last.totalBytes, 5);
    expect(acceptEncoding, 'identity');
    manager.close();
  });

  test('requests identity encoding again after a redirect', () async {
    final receivedEncodings = <String?>[];
    server.listen((request) async {
      receivedEncodings.add(
        request.headers.value(HttpHeaders.acceptEncodingHeader),
      );
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/runtime.zip',
        );
      } else {
        request.response.contentLength = 5;
        request.response.add([104, 101, 108, 108, 111]);
      }
      await request.response.close();
    });
    final manager = DownloadManager();

    final result = await manager.download(
      source: _serverUri(server).replace(path: '/redirect'),
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );

    expect(await result.file.readAsString(), 'hello');
    expect(receivedEncodings, ['identity', 'identity']);
    manager.close();
  });

  test('resumes a partial download with an HTTP range request', () async {
    final receivedRanges = <String?>[];
    server.listen((request) async {
      receivedRanges.add(request.headers.value(HttpHeaders.rangeHeader));
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 2-4/5',
      );
      request.response.contentLength = 3;
      request.response.add([108, 108, 111]);
      await request.response.close();
    });
    final partial = File(
      '${destinationDirectory.path}${Platform.pathSeparator}runtime.zip.part',
    );
    await partial.writeAsString('he');
    final progress = <DownloadProgress>[];
    final manager = DownloadManager();

    final result = await manager.download(
      source: _serverUri(server),
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      onProgress: progress.add,
    );

    expect(receivedRanges, ['bytes=2-']);
    expect(await result.file.readAsString(), 'hello');
    expect(progress.last.downloadedBytes, 5);
    expect(progress.last.totalBytes, 5);
    manager.close();
  });

  test('restarts safely when the server returns an invalid range', () async {
    final receivedRanges = <String?>[];
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      receivedRanges.add(range);
      if (range != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-4/5',
        );
      }
      request.response.contentLength = 5;
      request.response.add([104, 101, 108, 108, 111]);
      await request.response.close();
    });
    final partial = File(
      '${destinationDirectory.path}${Platform.pathSeparator}runtime.zip.part',
    );
    await partial.writeAsString('he');
    final manager = DownloadManager();

    final result = await manager.download(
      source: _serverUri(server),
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );

    expect(receivedRanges, ['bytes=2-', null]);
    expect(await result.file.readAsString(), 'hello');
    manager.close();
  });

  test('checksum failure preserves an existing final file', () async {
    server.listen((request) async {
      request.response.add([119, 111, 114, 108, 100]);
      await request.response.close();
    });
    final target = File(
      '${destinationDirectory.path}${Platform.pathSeparator}runtime.zip',
    );
    await target.writeAsString('keep me');
    final manager = DownloadManager();

    await expectLater(
      manager.download(
        source: _serverUri(server),
        destinationDirectory: destinationDirectory,
        fileName: 'runtime.zip',
        expectedSha256:
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      ),
      throwsA(isA<DownloadIntegrityException>()),
    );

    expect(await target.readAsString(), 'keep me');
    expect(File('${target.path}.part').existsSync(), isFalse);
    manager.close();
  });

  test('reuses a verified final file without a network request', () async {
    var requestCount = 0;
    server.listen((request) async {
      requestCount += 1;
      request.response.add([104, 101, 108, 108, 111]);
      await request.response.close();
    });
    final target = File(
      '${destinationDirectory.path}${Platform.pathSeparator}runtime.zip',
    );
    await target.writeAsString('hello');
    final manager = DownloadManager();

    final result = await manager.download(
      source: _serverUri(server),
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );

    expect(result.fromCache, isTrue);
    expect(result.file.path, target.path);
    expect(result.sourceUri, isNull);
    expect(requestCount, 0);
    manager.close();
  });

  test('cancels an active download and keeps the partial file', () async {
    final releaseResponse = Completer<void>();
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 5;
      request.response.add([104, 101]);
      await request.response.flush();
      await releaseResponse.future;
      request.response.add([108, 108, 111]);
      await request.response.close();
    });
    final cancellationToken = DownloadCancellationToken();
    final manager = DownloadManager();

    try {
      await expectLater(
        manager.download(
          source: _serverUri(server),
          destinationDirectory: destinationDirectory,
          fileName: 'runtime.zip',
          expectedSha256:
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          cancellationToken: cancellationToken,
          onProgress: (_) => cancellationToken.cancel(),
        ),
        throwsA(isA<DownloadCancelledException>()),
      );
    } finally {
      releaseResponse.complete();
    }

    final partial = File(
      '${destinationDirectory.path}${Platform.pathSeparator}runtime.zip.part',
    );
    expect(await partial.readAsString(), 'he');
    expect(
      File(
        '${destinationDirectory.path}${Platform.pathSeparator}runtime.zip',
      ).existsSync(),
      isFalse,
    );
    manager.close(force: true);
  });

  test('times out when the server does not send response headers', () async {
    final releaseResponse = Completer<void>();
    server.listen((request) async {
      await releaseResponse.future;
      await request.response.close();
    });
    final manager = DownloadManager(timeout: const Duration(milliseconds: 50));

    try {
      await expectLater(
        manager.download(
          source: _serverUri(server),
          destinationDirectory: destinationDirectory,
          fileName: 'runtime.zip',
          expectedSha256:
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        ),
        throwsA(isA<DownloadTimeoutException>()),
      );
    } finally {
      releaseResponse.complete();
      manager.close(force: true);
    }
  });

  test('falls back to the next source after an HTTP failure', () async {
    final requestedPaths = <String>[];
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      if (request.uri.path == '/official.zip') {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.add([104, 101, 108, 108, 111]);
      }
      await request.response.close();
    });
    final manager = DownloadManager();
    final sources = [
      _serverUri(server).replace(path: '/official.zip'),
      _serverUri(server).replace(path: '/mirror.zip'),
    ];

    final result = await manager.downloadFromSources(
      sources: sources,
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );

    expect(requestedPaths, ['/official.zip', '/mirror.zip']);
    expect(await result.file.readAsString(), 'hello');
    expect(result.sourceUri, sources.last);
    expect(result.usedFallback, isTrue);
    manager.close();
  });

  test('does not request a mirror when the official source succeeds', () async {
    final requestedPaths = <String>[];
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      request.response.add([104, 101, 108, 108, 111]);
      await request.response.close();
    });
    final manager = DownloadManager();
    final sources = [
      _serverUri(server).replace(path: '/official.zip'),
      _serverUri(server).replace(path: '/mirror.zip'),
    ];

    final result = await manager.downloadFromSources(
      sources: sources,
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );

    expect(requestedPaths, ['/official.zip']);
    expect(result.sourceUri, sources.first);
    expect(result.usedFallback, isFalse);
    manager.close();
  });

  test('cancellation stops without requesting a mirror', () async {
    final requestedPaths = <String>[];
    final releaseResponse = Completer<void>();
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      request.response.bufferOutput = false;
      request.response.contentLength = 5;
      request.response.add([104, 101]);
      await request.response.flush();
      await releaseResponse.future;
      request.response.add([108, 108, 111]);
      await request.response.close();
    });
    final manager = DownloadManager();
    final token = DownloadCancellationToken();

    try {
      await expectLater(
        manager.downloadFromSources(
          sources: [
            _serverUri(server).replace(path: '/official.zip'),
            _serverUri(server).replace(path: '/mirror.zip'),
          ],
          destinationDirectory: destinationDirectory,
          fileName: 'runtime.zip',
          expectedSha256:
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          cancellationToken: token,
          onProgress: (_) => token.cancel(),
        ),
        throwsA(isA<DownloadCancelledException>()),
      );
    } finally {
      releaseResponse.complete();
    }

    expect(requestedPaths, ['/official.zip']);
    manager.close(force: true);
  });

  test('starts a mirror from zero after official integrity failure', () async {
    final requestedRanges = <String?>[];
    final failures = <DownloadSourceFailure>[];
    server.listen((request) async {
      requestedRanges.add(request.headers.value(HttpHeaders.rangeHeader));
      request.response.add(
        request.uri.path == '/official.zip'
            ? [119, 114, 111, 110, 103]
            : [104, 101, 108, 108, 111],
      );
      await request.response.close();
    });
    final manager = DownloadManager();

    final result = await manager.downloadFromSources(
      sources: [
        _serverUri(server).replace(path: '/official.zip'),
        _serverUri(server).replace(path: '/mirror.zip'),
      ],
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      onSourceFailure: failures.add,
    );

    expect(requestedRanges, [null, null]);
    expect(await result.file.readAsString(), 'hello');
    expect(result.usedFallback, isTrue);
    expect(failures.single.kind, DownloadSourceFailureKind.integrity);
    manager.close();
  });

  test('does not resume a mirror partial from the official source', () async {
    final ranges = <String?>[];
    server.listen((request) async {
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      request.response.add([104, 101, 108, 108, 111]);
      await request.response.close();
    });
    const digest =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
    final target = File(
      '${destinationDirectory.path}${Platform.pathSeparator}runtime.zip',
    );
    final partial = File('${target.path}.part');
    final metadata = File('${partial.path}.source');
    final official = _serverUri(server).replace(path: '/official.zip');
    final mirror = _serverUri(server).replace(path: '/mirror.zip');
    await partial.writeAsString('he');
    await metadata.writeAsString('$digest\n$mirror\n');
    final manager = DownloadManager();

    final result = await manager.downloadFromSources(
      sources: [official, mirror],
      destinationDirectory: destinationDirectory,
      fileName: 'runtime.zip',
      expectedSha256: digest,
    );

    expect(ranges, [null]);
    expect(await result.file.readAsString(), 'hello');
    expect(await metadata.exists(), isFalse);
    manager.close();
  });

  test('reports every source when all downloads fail', () async {
    server.listen((request) async {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    final manager = DownloadManager();
    final sources = [
      _serverUri(server).replace(path: '/official.zip'),
      _serverUri(server).replace(path: '/mirror.zip'),
    ];

    await expectLater(
      manager.downloadFromSources(
        sources: sources,
        destinationDirectory: destinationDirectory,
        fileName: 'runtime.zip',
        expectedSha256:
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      ),
      throwsA(
        isA<DownloadSourcesExhaustedException>().having(
          (error) => error.failures.map((failure) => failure.source),
          'failed sources',
          orderedEquals(sources),
        ),
      ),
    );

    manager.close();
  });

  test(
    'does not hide a local file-system failure by switching sources',
    () async {
      var requestCount = 0;
      server.listen((request) async {
        requestCount += 1;
        request.response.add([104, 101, 108, 108, 111]);
        await request.response.close();
      });
      final invalidDestination = Directory(
        '${destinationDirectory.path}${Platform.pathSeparator}not-a-directory',
      );
      await File(invalidDestination.path).writeAsString('file');
      final manager = DownloadManager();

      await expectLater(
        manager.downloadFromSources(
          sources: [
            _serverUri(server).replace(path: '/official.zip'),
            _serverUri(server).replace(path: '/mirror.zip'),
          ],
          destinationDirectory: invalidDestination,
          fileName: 'runtime.zip',
          expectedSha256:
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(requestCount, 0);
      manager.close();
    },
  );
}

Uri _serverUri(HttpServer server) =>
    Uri.parse('http://${server.address.host}:${server.port}/runtime.zip');
