final class LicenseAcceptanceRegistry {
  final Set<String> _accepted = {};

  bool contains(String id) => _accepted.contains(id);

  void acceptAll(Iterable<String> ids) {
    for (final id in ids) {
      if (id.trim().isEmpty) {
        throw ArgumentError.value(id, 'ids', 'license id must not be blank');
      }
      _accepted.add(id);
    }
  }

  void clear() => _accepted.clear();
}
