import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum ServiceProbeStatus {
  identified,
  notRecognized,
  timedOut,
  connectionFailed,
  protocolError,
}

final class ServiceProbeResult {
  const ServiceProbeResult({
    required this.status,
    required this.service,
    required this.message,
    this.version,
  });

  final ServiceProbeStatus status;
  final String service;
  final String message;
  final String? version;

  bool get identified => status == ServiceProbeStatus.identified;
}

abstract interface class TcpProbeProtocol {
  String get serviceName;
  int get defaultPort;
  int get maxResponseBytes;
  Uint8List? get request;

  bool isResponseComplete(Uint8List response);
  ServiceProbeResult parseResponse(Uint8List response);
}

typedef SocketConnector =
    Future<Socket> Function(String host, int port, Duration timeout);

final class TcpServiceProbe {
  TcpServiceProbe({SocketConnector? connector})
    : _connector = connector ?? _connect;

  final SocketConnector _connector;

  static Future<Socket> _connect(String host, int port, Duration timeout) =>
      Socket.connect(host, port, timeout: timeout);

  Future<ServiceProbeResult> probe(
    TcpProbeProtocol protocol, {
    String host = '127.0.0.1',
    int? port,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    Socket? socket;
    try {
      socket = await _connector(
        host,
        port ?? protocol.defaultPort,
        timeout,
      ).timeout(timeout);
      final request = protocol.request;
      if (request != null) {
        socket.add(request);
        await socket.flush();
      }
      final response = await _readResponse(socket, protocol, timeout);
      return protocol.parseResponse(response);
    } on TimeoutException {
      return ServiceProbeResult(
        status: ServiceProbeStatus.timedOut,
        service: protocol.serviceName,
        message:
            '${protocol.serviceName} probe timed out after ${timeout.inMilliseconds} ms',
      );
    } on SocketException catch (error) {
      return ServiceProbeResult(
        status: ServiceProbeStatus.connectionFailed,
        service: protocol.serviceName,
        message: '${protocol.serviceName} connection failed: ${error.message}',
      );
    } on FormatException catch (error) {
      return ServiceProbeResult(
        status: ServiceProbeStatus.protocolError,
        service: protocol.serviceName,
        message: '${protocol.serviceName} protocol error: ${error.message}',
      );
    } finally {
      socket?.destroy();
    }
  }

  Future<Uint8List> _readResponse(
    Socket socket,
    TcpProbeProtocol protocol,
    Duration timeout,
  ) {
    final completer = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> subscription;
    late final Timer timer;

    void completeWithBytes() {
      if (!completer.isCompleted) completer.complete(bytes.takeBytes());
    }

    subscription = socket.listen(
      (chunk) {
        if (completer.isCompleted) return;
        bytes.add(chunk);
        if (bytes.length > protocol.maxResponseBytes) {
          completer.completeError(
            FormatException(
              'response exceeded ${protocol.maxResponseBytes} bytes',
            ),
          );
          return;
        }
        final response = bytes.toBytes();
        if (protocol.isResponseComplete(response)) completeWithBytes();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      onDone: completeWithBytes,
      cancelOnError: false,
    );
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('No complete response received', timeout),
        );
      }
    });

    return completer.future.whenComplete(() async {
      timer.cancel();
      await subscription.cancel();
    });
  }
}

final class MySqlHandshakeProtocol implements TcpProbeProtocol {
  const MySqlHandshakeProtocol();

  @override
  String get serviceName => 'MySQL';

  @override
  int get defaultPort => 3306;

  @override
  int get maxResponseBytes => 64 * 1024;

  @override
  Uint8List? get request => null;

  @override
  bool isResponseComplete(Uint8List response) {
    if (response.length < 4) return false;
    return response.length >= 4 + _payloadLength(response);
  }

  @override
  ServiceProbeResult parseResponse(Uint8List response) {
    if (response.length < 5) {
      throw const FormatException('incomplete handshake packet');
    }
    final payloadLength = _payloadLength(response);
    if (payloadLength < 2 || response.length < payloadLength + 4) {
      throw const FormatException('invalid handshake packet length');
    }
    if (response[3] != 0 || response[4] != 10) {
      return const ServiceProbeResult(
        status: ServiceProbeStatus.notRecognized,
        service: 'MySQL',
        message: 'TCP endpoint did not return a MySQL protocol 10 handshake',
      );
    }

    final versionEnd = response.indexOf(0, 5);
    if (versionEnd < 6 || versionEnd > payloadLength + 3) {
      throw const FormatException('handshake has no valid server version');
    }
    final version = ascii.decode(
      response.sublist(5, versionEnd),
      allowInvalid: false,
    );
    if (!RegExp(r'^\d+(?:\.\d+)+').hasMatch(version)) {
      return const ServiceProbeResult(
        status: ServiceProbeStatus.notRecognized,
        service: 'MySQL',
        message: 'Handshake signature contained an invalid MySQL version',
      );
    }
    return ServiceProbeResult(
      status: ServiceProbeStatus.identified,
      service: serviceName,
      version: version,
      message: 'MySQL $version responded with a protocol 10 handshake',
    );
  }

  int _payloadLength(Uint8List response) =>
      response[0] | (response[1] << 8) | (response[2] << 16);
}

final class RedisPingProtocol implements TcpProbeProtocol {
  const RedisPingProtocol();

  @override
  String get serviceName => 'Redis';

  @override
  int get defaultPort => 6379;

  @override
  int get maxResponseBytes => 8 * 1024;

  @override
  Uint8List get request =>
      Uint8List.fromList(ascii.encode('*1\r\n\$4\r\nPING\r\n'));

  @override
  bool isResponseComplete(Uint8List response) {
    final length = response.length;
    return length >= 2 &&
        response[length - 2] == 13 &&
        response[length - 1] == 10;
  }

  @override
  ServiceProbeResult parseResponse(Uint8List response) {
    if (!isResponseComplete(response)) {
      throw const FormatException('incomplete RESP response');
    }
    final line = ascii.decode(response, allowInvalid: false).trim();
    if (line == '+PONG') {
      return const ServiceProbeResult(
        status: ServiceProbeStatus.identified,
        service: 'Redis',
        message: 'Redis responded to PING with RESP PONG',
      );
    }
    if (line.startsWith('-')) {
      return ServiceProbeResult(
        status: ServiceProbeStatus.protocolError,
        service: serviceName,
        message: 'Redis returned an error to PING: ${line.substring(1)}',
      );
    }
    return const ServiceProbeResult(
      status: ServiceProbeStatus.notRecognized,
      service: 'Redis',
      message: 'TCP endpoint did not return RESP PONG',
    );
  }
}
