import 'package:flutter/material.dart';

enum ComponentStatus { checking, ready, missing, attention }

enum ComponentGroup { flutter, server, services, tools }

class EnvironmentComponent {
  const EnvironmentComponent({
    required this.id,
    required this.name,
    required this.group,
    required this.icon,
    required this.required,
    required this.status,
    this.version,
    this.detail,
    this.updateAvailable = false,
  });

  final String id;
  final String name;
  final ComponentGroup group;
  final IconData icon;
  final bool required;
  final ComponentStatus status;
  final String? version;
  final String? detail;
  final bool updateAvailable;

  EnvironmentComponent copyWith({
    ComponentStatus? status,
    String? version,
    String? detail,
    bool? updateAvailable,
  }) {
    return EnvironmentComponent(
      id: id,
      name: name,
      group: group,
      icon: icon,
      required: required,
      status: status ?? this.status,
      version: version ?? this.version,
      detail: detail ?? this.detail,
      updateAvailable: updateAvailable ?? this.updateAvailable,
    );
  }
}
