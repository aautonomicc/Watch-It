import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/skaists_bloom.dart';

void main() {
  test('canonical bloom SVG is the wellness mandala, no wordmark', () {
    final svg = File('assets/skaists_bloom.svg').readAsStringSync();
    expect(svg, contains('<title>beehive-WELLness mark</title>'));
    expect(svg, contains('#9C6FD6'));
    expect(svg, contains('#6FA9E0'));
    expect(svg, contains('#45C2DC'));
    expect(svg, contains('#8FD14F'));
    expect(svg, contains('cdee76a'));
    expect(svg, contains('viewBox="0 0 1025 1026"'));
    expect(svg, contains('fill-rule="evenodd"'));
    expect(svg.toLowerCase(), isNot(contains('<text')));
    expect(svg, isNot(contains('W@tch')));
    expect(svg, isNot(contains('Watch-It')));
    expect(kSkaistsBloomSvgAsset, 'assets/skaists_bloom.svg');
    expect(kSkaistsBloomMarkAsset, 'assets/skaists_bloom.png');
    expect(File('assets/skaists_bloom.png').existsSync(), isTrue);
  });

  test('wellness tokens match the mark colorway', () {
    expect(WiTokens.bloomCore, const Color(0xFF9C6FD6));
    expect(WiTokens.bloomBlue, const Color(0xFF6FA9E0));
    expect(WiTokens.bloomTeal, const Color(0xFF45C2DC));
    expect(WiTokens.bloomRim, const Color(0xFF8FD14F));
  });
}
