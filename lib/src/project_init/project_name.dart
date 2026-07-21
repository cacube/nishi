import 'dart:convert';

import 'package:crypto/crypto.dart';

final class ProjectName {
  const ProjectName._({required this.directoryName, required this.packageName});

  final String directoryName;
  final String packageName;
  String get databaseName => packageName;

  factory ProjectName.parse(String value) {
    _validateDirectoryName(value);
    var identifier = value
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '_')
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (identifier.isEmpty) {
      final digest = sha256.convert(utf8.encode(value)).toString();
      identifier = 'lc_project_${digest.substring(0, 8)}';
    } else if (RegExp(r'^[0-9]').hasMatch(identifier) ||
        _dartKeywords.contains(identifier)) {
      identifier = 'lc_$identifier';
    }
    if (identifier.length > 63) {
      final digest = sha256.convert(utf8.encode(value)).toString();
      identifier = '${identifier.substring(0, 54)}_${digest.substring(0, 8)}';
    }
    return ProjectName._(directoryName: value, packageName: identifier);
  }
}

final class ProjectNameException implements Exception {
  const ProjectNameException(this.message);

  final String message;

  @override
  String toString() => message;
}

void _validateDirectoryName(String value) {
  if (value.isEmpty || value == '.' || value == '..') {
    throw const ProjectNameException('项目名不能为空，也不能是 . 或 ..');
  }
  if (value != value.trim() || value.endsWith('.')) {
    throw const ProjectNameException('项目名不能以空格或点结尾');
  }
  if (RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(value)) {
    throw const ProjectNameException('项目名包含系统不允许的字符');
  }
  final baseName = value.split('.').first.toUpperCase();
  if (_windowsReservedNames.contains(baseName)) {
    throw const ProjectNameException('项目名是 Windows 保留名称');
  }
}

const _windowsReservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

const _dartKeywords = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};
