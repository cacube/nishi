import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

typedef DownloadProgressCallback = void Function(DownloadProgress progress);

final class DownloadProgress {
  const DownloadProgress({
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final int downloadedBytes;
  final int? totalBytes;

  double? get fraction => switch (totalBytes) {
    final total? when total > 0 => downloadedBytes / total,
    _ => null,
  };
}

final class DownloadResult {
  const DownloadResult({required this.file, required this.fromCache});

  final File file;
  final bool fromCache;
}

final class DownloadCancellationToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
    _listeners.clear();
  }

  void throwIfCancelled() {
    if (_isCancelled) {
      throw const DownloadCancelledException();
    }
  }

  void Function() _onCancel(void Function() listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

final class DownloadManager {
  DownloadManager({
    HttpClient? httpClient,
    this.timeout = const Duration(minutes: 5),
  }) : assert(timeout > Duration.zero),
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null {
    _httpClient.autoUncompress = false;
  }

  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

  Future<DownloadResult> download({
    required Uri source,
    required Directory destinationDirectory,
    required String fileName,
    required String expectedSha256,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    _validateFileName(fileName);
    final normalizedSha256 = _normalizeSha256(expectedSha256);
    await destinationDirectory.create(recursive: true);

    final target = File(
      '${destinationDirectory.path}${Platform.pathSeparator}$fileName',
    );
    final partial = File('${target.path}.part');
    if (await target.exists() && await _sha256Of(target) == normalizedSha256) {
      cancellationToken?.throwIfCancelled();
      if (await partial.exists()) {
        await partial.delete();
      }
      final cachedBytes = await target.length();
      onProgress?.call(
        DownloadProgress(downloadedBytes: cachedBytes, totalBytes: cachedBytes),
      );
      return DownloadResult(file: target, fromCache: true);
    }

    final partialLength = await partial.exists() ? await partial.length() : 0;
    var openedResponse = await _openResponse(
      source,
      rangeStart: partialLength > 0 ? partialLength : null,
      cancellationToken: cancellationToken,
    );
    try {
      var response = openedResponse.response;
      var resumesDownload =
          partialLength > 0 &&
          response.statusCode == HttpStatus.partialContent &&
          _rangeStartsAt(response, partialLength);

      final rejectedRange =
          partialLength > 0 &&
          (response.statusCode == HttpStatus.requestedRangeNotSatisfiable ||
              (response.statusCode == HttpStatus.partialContent &&
                  !resumesDownload));
      if (rejectedRange) {
        openedResponse.abort(
          const HttpException('Server returned an invalid range response'),
        );
        openedResponse.dispose();
        openedResponse = await _openResponse(
          source,
          cancellationToken: cancellationToken,
        );
        response = openedResponse.response;
        resumesDownload = false;
      }

      if (response.statusCode != HttpStatus.ok && !resumesDownload) {
        await _drainResponse(
          openedResponse,
          source: source,
          cancellationToken: cancellationToken,
        );
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}',
          uri: source,
        );
      }

      await _writeResponse(
        openedResponse,
        partial: partial,
        existingBytes: resumesDownload ? partialLength : 0,
        append: resumesDownload,
        source: source,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    } catch (_) {
      cancellationToken?.throwIfCancelled();
      rethrow;
    } finally {
      openedResponse.dispose();
    }

    cancellationToken?.throwIfCancelled();
    final actualSha256 = await _sha256Of(partial);
    cancellationToken?.throwIfCancelled();
    if (actualSha256 != normalizedSha256) {
      await partial.delete();
      throw DownloadIntegrityException(
        expectedSha256: normalizedSha256,
        actualSha256: actualSha256,
      );
    }

    await _activate(partial: partial, target: target);
    return DownloadResult(file: target, fromCache: false);
  }

  Future<_OpenedResponse> _openResponse(
    Uri source, {
    int? rangeStart,
    DownloadCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final timeoutError = DownloadTimeoutException(
      source: source,
      timeout: timeout,
    );
    final request = await _httpClient
        .getUrl(source)
        .timeout(timeout, onTimeout: () => throw timeoutError);
    cancellationToken?.throwIfCancelled();
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (rangeStart != null) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-');
    }

    final removeCancellationListener = cancellationToken?._onCancel(
      () => request.abort(const DownloadCancelledException()),
    );
    try {
      final response = await request.close().timeout(
        timeout,
        onTimeout: () {
          request.abort(timeoutError);
          throw timeoutError;
        },
      );
      return _OpenedResponse(
        request: request,
        response: response,
        removeCancellationListener: removeCancellationListener ?? () {},
      );
    } catch (_) {
      removeCancellationListener?.call();
      cancellationToken?.throwIfCancelled();
      rethrow;
    }
  }

  Future<void> _writeResponse(
    _OpenedResponse openedResponse, {
    required File partial,
    required int existingBytes,
    required bool append,
    required Uri source,
    required DownloadProgressCallback? onProgress,
    required DownloadCancellationToken? cancellationToken,
  }) async {
    final response = openedResponse.response;
    final sink = partial.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var downloadedBytes = existingBytes;
    final totalBytes = response.contentLength >= 0
        ? downloadedBytes + response.contentLength
        : null;
    final timeoutError = DownloadTimeoutException(
      source: source,
      timeout: timeout,
    );
    final completed = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    var stopWriting = false;
    subscription = response
        .timeout(
          timeout,
          onTimeout: (eventSink) {
            openedResponse.abort(timeoutError);
            eventSink.addError(timeoutError);
          },
        )
        .listen(
          (chunk) {
            if (stopWriting) return;
            try {
              sink.add(chunk);
              downloadedBytes += chunk.length;
              onProgress?.call(
                DownloadProgress(
                  downloadedBytes: downloadedBytes,
                  totalBytes: totalBytes,
                ),
              );
              if (cancellationToken?.isCancelled ?? false) {
                stopWriting = true;
                if (!completed.isCompleted) {
                  completed.completeError(const DownloadCancelledException());
                }
              }
            } catch (error, stackTrace) {
              stopWriting = true;
              if (!completed.isCompleted) {
                completed.completeError(error, stackTrace);
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completed.isCompleted) {
              completed.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!completed.isCompleted) {
              completed.complete();
            }
          },
          cancelOnError: true,
        );
    final removeStreamCancellationListener = cancellationToken?._onCancel(() {
      const error = DownloadCancelledException();
      stopWriting = true;
      openedResponse.abort(error);
      if (!completed.isCompleted) {
        completed.completeError(error);
      }
    });
    try {
      await completed.future;
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      cancellationToken?.throwIfCancelled();
      rethrow;
    } finally {
      removeStreamCancellationListener?.call();
      unawaited(subscription.cancel());
    }
  }

  Future<void> _drainResponse(
    _OpenedResponse openedResponse, {
    required Uri source,
    required DownloadCancellationToken? cancellationToken,
  }) async {
    final timeoutError = DownloadTimeoutException(
      source: source,
      timeout: timeout,
    );
    try {
      await openedResponse.response.drain<void>().timeout(
        timeout,
        onTimeout: () {
          openedResponse.abort(timeoutError);
          throw timeoutError;
        },
      );
    } catch (_) {
      cancellationToken?.throwIfCancelled();
      rethrow;
    }
  }

  void close({bool force = false}) {
    if (_ownsHttpClient) {
      _httpClient.close(force: force);
    }
  }
}

final class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'DownloadCancelledException';
}

final class DownloadTimeoutException implements Exception {
  const DownloadTimeoutException({required this.source, required this.timeout});

  final Uri source;
  final Duration timeout;

  @override
  String toString() =>
      'DownloadTimeoutException(source: $source, timeout: $timeout)';
}

final class DownloadIntegrityException implements Exception {
  const DownloadIntegrityException({
    required this.expectedSha256,
    required this.actualSha256,
  });

  final String expectedSha256;
  final String actualSha256;

  @override
  String toString() =>
      'DownloadIntegrityException(expected: $expectedSha256, actual: $actualSha256)';
}

final class _OpenedResponse {
  _OpenedResponse({
    required this.request,
    required this.response,
    required this.removeCancellationListener,
  });

  final HttpClientRequest request;
  final HttpClientResponse response;
  final void Function() removeCancellationListener;
  bool _disposed = false;

  void abort(Object error) => request.abort(error);

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    removeCancellationListener();
  }
}

String _normalizeSha256(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
    throw ArgumentError.value(
      value,
      'expectedSha256',
      'Must be 64 hex characters',
    );
  }
  return normalized;
}

void _validateFileName(String fileName) {
  if (fileName.isEmpty ||
      fileName == '.' ||
      fileName == '..' ||
      fileName.contains('/') ||
      fileName.contains(r'\')) {
    throw ArgumentError.value(
      fileName,
      'fileName',
      'Must be a plain file name',
    );
  }
}

Future<String> _sha256Of(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

bool _rangeStartsAt(HttpClientResponse response, int expectedStart) {
  final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
  final match = RegExp(
    r'^bytes (\d+)-\d+/(?:\d+|\*)$',
  ).firstMatch(contentRange ?? '');
  return match != null && int.parse(match.group(1)!) == expectedStart;
}

Future<void> _activate({required File partial, required File target}) async {
  if (!await target.exists()) {
    await partial.rename(target.path);
    return;
  }

  final backup = File('${target.path}.previous');
  if (await backup.exists()) {
    await backup.delete();
  }
  await target.rename(backup.path);
  try {
    await partial.rename(target.path);
  } catch (_) {
    if (!await target.exists() && await backup.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  }
  try {
    await backup.delete();
  } on FileSystemException {
    // The verified target is already active; stale backup cleanup can retry later.
  }
}
