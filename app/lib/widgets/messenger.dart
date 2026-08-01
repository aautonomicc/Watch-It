import 'package:flutter/material.dart';

/// App-wide messenger so background work (the upgrade migration pass,
/// import passes) can report its outcome whatever screen is on top by
/// then. Attached to the MaterialApp in main().
final GlobalKey<ScaffoldMessengerState> wiMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
