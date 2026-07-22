String? latestAndroidSdkPlatformVersion(Iterable<String> directoryNames) {
  int? highestApi;
  final pattern = RegExp(r'^android-(\d+)(?:-ext\d+)?$');
  for (final name in directoryNames) {
    final api = int.tryParse(pattern.firstMatch(name)?.group(1) ?? '');
    if (api != null && (highestApi == null || api > highestApi)) {
      highestApi = api;
    }
  }
  return highestApi == null ? null : '$highestApi.0.0';
}
