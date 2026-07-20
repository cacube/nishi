import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dev_environment_manager/src/compatibility/compatibility_requirement.dart';
import 'package:dev_environment_manager/src/compatibility/service_probe.dart';
import 'package:dev_environment_manager/src/compatibility/software_version.dart';
import 'package:dev_environment_manager/src/compatibility/version_output_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SoftwareVersion', () {
    test('compares numeric segments and pre-release versions', () {
      expect(
        SoftwareVersion.parse('1.10.0') > SoftwareVersion.parse('1.9.9'),
        isTrue,
      );
      expect(
        SoftwareVersion.parse('17.0') == SoftwareVersion.parse('17.0.0'),
        isTrue,
      );
      expect(
        SoftwareVersion.parse('3.22.0-beta.2') <
            SoftwareVersion.parse('3.22.0'),
        isTrue,
      );
      expect(
        SoftwareVersion.parse('1.8.0_402') < SoftwareVersion.parse('17.0.0'),
        isTrue,
      );
    });

    test('compares JDK build identifiers', () {
      expect(
        SoftwareVersion.parse('17.0.19+11') >
            SoftwareVersion.parse('17.0.19+10'),
        isTrue,
      );
      expect(
        SoftwareVersion.parse('17.0.20+1') >
            SoftwareVersion.parse('17.0.19+10'),
        isTrue,
      );
    });
  });

  group('VersionOutputParser', () {
    const parser = VersionOutputParser();
    final cases = <SoftwareComponent, (String, String)>{
      SoftwareComponent.flutter: ('Flutter 3.32.5 - channel stable', '3.32.5'),
      SoftwareComponent.java: (
        'openjdk version "17.0.15" 2025-04-15',
        '17.0.15',
      ),
      SoftwareComponent.go: ('go version go1.24.4 darwin/arm64', '1.24.4'),
      SoftwareComponent.node: ('v22.16.0', '22.16.0'),
      SoftwareComponent.npm: ('10.9.2', '10.9.2'),
      SoftwareComponent.mysql: (
        'mysql  Ver 8.0.42 for macos15 on arm64 (MySQL Community Server)',
        '8.0.42',
      ),
      SoftwareComponent.redis: (
        'Redis server v=7.2.8 sha=00000000 malloc=libc',
        '7.2.8',
      ),
      SoftwareComponent.git: ('git version 2.49.0', '2.49.0'),
      SoftwareComponent.xcode: ('Xcode 16.4\nBuild version 16F6', '16.4'),
    };

    for (final entry in cases.entries) {
      test('extracts ${entry.key.name}', () {
        expect(
          parser.extract(entry.key, entry.value.$1).toString(),
          entry.value.$2,
        );
      });
    }

    test('prefers MySQL Distrib version over client protocol version', () {
      final version = parser.extract(
        SoftwareComponent.mysql,
        'mysql  Ver 14.14 Distrib 5.7.44, for osx10.19 (arm64)',
      );
      expect(version.toString(), '5.7.44');
    });

    test('returns null for unrelated output', () {
      expect(parser.extract(SoftwareComponent.go, 'command not found'), isNull);
    });
  });

  test('CompatibilityRequirement distinguishes all three states', () {
    final requirement = CompatibilityRequirement(
      minimumVersion: SoftwareVersion.parse('1.24.0'),
    );
    expect(
      requirement.evaluate(SoftwareVersion.parse('1.24.1')),
      CompatibilityStatus.compatible,
    );
    expect(
      requirement.evaluate(SoftwareVersion.parse('1.23.9')),
      CompatibilityStatus.outdated,
    );
    expect(requirement.evaluate(null), CompatibilityStatus.unknown);
  });

  group('service protocol parsers', () {
    test('recognizes a MySQL protocol 10 handshake and version', () {
      const protocol = MySqlHandshakeProtocol();
      final result = protocol.parseResponse(_mysqlHandshake('8.0.42'));
      expect(result.status, ServiceProbeStatus.identified);
      expect(result.version, '8.0.42');
    });

    test('does not mistake arbitrary bytes for MySQL', () {
      const protocol = MySqlHandshakeProtocol();
      final response = Uint8List.fromList([2, 0, 0, 0, 72, 0]);
      expect(
        protocol.parseResponse(response).status,
        ServiceProbeStatus.notRecognized,
      );
    });

    test('recognizes only a complete RESP PONG', () {
      const protocol = RedisPingProtocol();
      expect(
        protocol
            .parseResponse(Uint8List.fromList(ascii.encode('+PONG\r\n')))
            .identified,
        isTrue,
      );
      expect(
        protocol
            .parseResponse(Uint8List.fromList(ascii.encode('+OK\r\n')))
            .status,
        ServiceProbeStatus.notRecognized,
      );
    });
  });

  group('TcpServiceProbe', () {
    test('sends Redis PING and identifies PONG over TCP', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) async {
        final request = await client.first;
        expect(ascii.decode(request), '*1\r\n\$4\r\nPING\r\n');
        client.add(ascii.encode('+PONG\r\n'));
        await client.flush();
        await client.close();
      });

      final result = await TcpServiceProbe().probe(
        const RedisPingProtocol(),
        port: server.port,
      );
      expect(result.status, ServiceProbeStatus.identified);
    });

    test('reads a MySQL server-first handshake over TCP', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) async {
        client.add(_mysqlHandshake('8.4.5'));
        await client.flush();
        await client.close();
      });

      final result = await TcpServiceProbe().probe(
        const MySqlHandshakeProtocol(),
        port: server.port,
      );
      expect(result.status, ServiceProbeStatus.identified);
      expect(result.version, '8.4.5');
    });

    test('reports a clear timeout', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) {});

      final result = await TcpServiceProbe().probe(
        const RedisPingProtocol(),
        port: server.port,
        timeout: const Duration(milliseconds: 30),
      );
      expect(result.status, ServiceProbeStatus.timedOut);
      expect(result.message, contains('30 ms'));
    });
  });
}

Uint8List _mysqlHandshake(String version) {
  final payload = <int>[10, ...ascii.encode(version), 0, 1];
  final length = payload.length;
  return Uint8List.fromList([
    length & 0xff,
    (length >> 8) & 0xff,
    (length >> 16) & 0xff,
    0,
    ...payload,
  ]);
}
