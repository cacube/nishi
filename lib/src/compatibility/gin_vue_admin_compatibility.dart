import 'software_version.dart';

const ginVueAdminMinimumGoVersion = '1.24.2';
const ginVueAdminMinimumNode20Version = '20.19.0';
const ginVueAdminMinimumNode22Version = '22.12.0';

bool ginVueAdminGoIsCompatible(SoftwareVersion version) {
  return version >= SoftwareVersion.parse(ginVueAdminMinimumGoVersion);
}

bool ginVueAdminNodeIsCompatible(SoftwareVersion version) {
  return (version >= SoftwareVersion.parse(ginVueAdminMinimumNode20Version) &&
          version < SoftwareVersion.parse('21.0.0')) ||
      version >= SoftwareVersion.parse(ginVueAdminMinimumNode22Version);
}
