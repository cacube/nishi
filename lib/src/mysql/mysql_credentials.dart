import 'dart:convert';
import 'dart:io';

final class MySqlCredentials {
  const MySqlCredentials({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });

  final String host;
  final int port;
  final String username;
  final String password;
}

abstract interface class MySqlCredentialsReader {
  Future<MySqlCredentials?> read();
}

final class FileMySqlCredentialsReader implements MySqlCredentialsReader {
  const FileMySqlCredentialsReader(this.file);

  final File file;

  @override
  Future<MySqlCredentials?> read() async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('MySQL credentials must be a JSON object');
    }
    final host = decoded['host'];
    final port = decoded['port'];
    final username = decoded['username'];
    final password = decoded['password'];
    if (host is! String ||
        host.isEmpty ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        username is! String ||
        username.isEmpty ||
        password is! String ||
        password.isEmpty) {
      throw const FormatException('MySQL credentials are incomplete');
    }
    return MySqlCredentials(
      host: host,
      port: port,
      username: username,
      password: password,
    );
  }
}

final class EmptyMySqlCredentialsReader implements MySqlCredentialsReader {
  const EmptyMySqlCredentialsReader();

  @override
  Future<MySqlCredentials?> read() async => null;
}
