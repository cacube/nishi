# ADR 0003: Runtime Health and Updates

Status: Accepted

Runtime health and update availability are separate states. A compatible
installed runtime remains usable when a newer pinned version is available, so
an update must not change the machine from Ready to Setup Required.
Installation steps form a dependency graph, failures block only the failed
component and its dependants, and retry resumes from the failed step rather than
restarting setup. Externally managed tools such as Xcode are detected and
reported but never marked as installed by the Environment Manager.
