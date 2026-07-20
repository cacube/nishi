enum RuntimePlatform { windows, macos }

enum RuntimeArchitecture { x64, arm64 }

enum RuntimeArchiveType { zip, tarGz, dmg, pkg, msi, exe, raw }

enum RuntimeProvisioning { managed, external }

extension RuntimePlatformJson on RuntimePlatform {
  String get jsonValue => name;
}

extension RuntimeArchitectureJson on RuntimeArchitecture {
  String get jsonValue => name;
}

extension RuntimeArchiveTypeJson on RuntimeArchiveType {
  String get jsonValue => switch (this) {
    RuntimeArchiveType.tarGz => 'tar.gz',
    _ => name,
  };
}

extension RuntimeProvisioningJson on RuntimeProvisioning {
  String get jsonValue => name;
}

class RuntimeManifest {
  RuntimeManifest({
    required this.schemaVersion,
    required List<RuntimeComponent> components,
  }) : components = List.unmodifiable(components);

  final int schemaVersion;
  final List<RuntimeComponent> components;

  RuntimeComponent? componentById(String id) {
    for (final component in components) {
      if (component.id == id) {
        return component;
      }
    }
    return null;
  }
}

class RuntimeComponent {
  RuntimeComponent({
    required this.id,
    required this.displayName,
    required this.version,
    required this.minimumCompatibleVersion,
    required this.provisioning,
    required List<RuntimeArtifact> artifacts,
    required List<RuntimeExecutable> executables,
    required List<String> dependencies,
    this.service,
    this.androidSdk,
  }) : artifacts = List.unmodifiable(artifacts),
       executables = List.unmodifiable(executables),
       dependencies = List.unmodifiable(dependencies);

  final String id;
  final String displayName;
  final String version;
  final String minimumCompatibleVersion;
  final RuntimeProvisioning provisioning;
  final List<RuntimeArtifact> artifacts;
  final List<RuntimeExecutable> executables;
  final List<String> dependencies;
  final RuntimeServiceMetadata? service;
  final RuntimeAndroidSdkMetadata? androidSdk;

  bool get isManaged => provisioning == RuntimeProvisioning.managed;
  bool get isExternal => provisioning == RuntimeProvisioning.external;
}

class RuntimeAndroidSdkMetadata {
  RuntimeAndroidSdkMetadata({
    required List<String> packages,
    List<Uri> repositoryMirrorUrls = const [],
    required this.license,
  }) : packages = List.unmodifiable(packages),
       repositoryMirrorUrls = List.unmodifiable(repositoryMirrorUrls);

  final List<String> packages;
  final List<Uri> repositoryMirrorUrls;
  final RuntimeLicenseMetadata license;
}

class RuntimeLicenseMetadata {
  const RuntimeLicenseMetadata({
    required this.id,
    required this.displayName,
    required this.url,
  });

  final String id;
  final String displayName;
  final Uri url;
}

class RuntimeArtifact {
  RuntimeArtifact({
    required this.platform,
    required this.architecture,
    required this.officialUrl,
    List<Uri> mirrorUrls = const [],
    required this.sha256,
    required this.archiveType,
    this.archiveRoot = '',
    this.installSubdirectory = '',
  }) : mirrorUrls = List.unmodifiable(mirrorUrls);

  final RuntimePlatform platform;
  final RuntimeArchitecture architecture;
  final Uri officialUrl;
  final List<Uri> mirrorUrls;
  final String sha256;
  final RuntimeArchiveType archiveType;
  final String archiveRoot;
  final String installSubdirectory;

  String get targetKey => '${platform.jsonValue}/${architecture.jsonValue}';

  List<Uri> get downloadUrls => List.unmodifiable([officialUrl, ...mirrorUrls]);
}

class RuntimeExecutable {
  RuntimeExecutable({
    required this.platform,
    required List<RuntimeArchitecture> architectures,
    required this.path,
  }) : architectures = List.unmodifiable(architectures);

  final RuntimePlatform platform;
  final List<RuntimeArchitecture> architectures;
  final String path;
}

class RuntimeServiceMetadata {
  RuntimeServiceMetadata({
    required this.serviceName,
    required this.defaultPort,
    required this.startAutomatically,
    required this.dataDirectory,
    required List<String> healthCheckCommand,
  }) : healthCheckCommand = List.unmodifiable(healthCheckCommand);

  final String serviceName;
  final int defaultPort;
  final bool startAutomatically;
  final String dataDirectory;
  final List<String> healthCheckCommand;
}
