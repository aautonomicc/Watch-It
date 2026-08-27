/// The Terms of Use & Disclaimer text, shown as a first-launch accept
/// gate and readable any time from Settings → About.
library;

/// Bump when the terms change materially — every user is re-prompted to
/// accept on their next launch (their stored accepted version is lower).
/// v2 (2026-08-27): Channels — public channel publishing gets its own
/// section (publisher's sole responsibility, irrevocability, the app
/// neither hosts nor indexes channels).
const kTermsVersion = 2;

/// One-line lead-in above the sections.
const kTermsIntro =
    'Please read this before using W@tch. By using the app you agree to '
    'the following terms. If you do not agree, do not use the app.';

/// A titled block of the terms text.
class TermsSection {
  const TermsSection(this.title, this.body);

  final String title;
  final String body;
}

const kTermsSections = [
  TermsSection(
    '1. What W@tch is',
    'W@tch is an independent, open-source media player — a client for '
        'the decentralized Autonomi network. The developers do not host, '
        'store, index, curate, moderate, or control any content. All '
        'media is published to and fetched from a public peer-to-peer '
        'network by its users. The developers have no ability to remove, '
        'alter, or block content on that network, and no knowledge of '
        'what you access with the app.',
  ),
  TermsSection(
    '2. Your content is your responsibility',
    'You are solely responsible for everything you import, stream, '
        'download, share, or publish with W@tch. Only use content you '
        'own, that is in the public domain, or that you are licensed or '
        'otherwise authorized to use. Copyright and media laws differ '
        'between countries — it is your responsibility to comply with '
        'the laws that apply to you.',
  ),
  TermsSection(
    '3. Prohibited use',
    'You must not use W@tch to access, share, or publish content that '
        'infringes copyright or other rights, or that is unlawful where '
        'you live or where it is made available — including but not '
        'limited to pirated media and any illegal material of any kind. '
        'The developers do not condone, encourage, or accept any '
        'responsibility for such use.',
  ),
  TermsSection(
    '4. Publishing is permanent',
    'Data published to the Autonomi network is permanent. It cannot be '
        'edited, taken down, or deleted by anyone — including you and '
        'the developers. Never publish anything you do not have the '
        'right to make permanently and publicly available.',
  ),
  TermsSection(
    '5. Public channels',
    'A channel publishes media publicly: anyone holding the channel '
        'code can fetch and watch it, forever. As a channel publisher '
        'you are solely responsible for everything your channel makes '
        'available — only publish content you created yourself or hold '
        'the rights to distribute publicly. Channel publishes are '
        'signed by your channel key and are irrevocable: they cannot '
        'be edited, taken down, or deleted by anyone, and removing an '
        'item from a channel only stops new subscribers from seeing '
        'it. The developers do not host, index, distribute, endorse, '
        'or moderate any channel; channel content reaches you directly '
        'from the public network, and the prohibited-use terms above '
        'apply in full to what you publish, watch, and re-share.',
  ),
  TermsSection(
    '6. Wallet and payments',
    'The built-in publishing wallet is a "hot" wallet stored on your '
        'device and controlled only by you. The developers never see, '
        'hold, or have access to your keys or funds, and cannot recover '
        'a lost key or reverse a transaction. Cryptocurrency carries '
        'risk; keep only small amounts in the wallet. Network fees paid '
        'for publishing are non-refundable.',
  ),
  TermsSection(
    '7. Third-party services',
    'Metadata and artwork can optionally be fetched from TMDB using '
        'your own API key, subject to TMDB\'s terms. On desktop, an '
        'optional update check contacts GitHub. Neither the developers '
        'nor these services endorse or verify any content played '
        'through the app.',
  ),
  TermsSection(
    '8. No warranty',
    'W@tch is alpha software provided "as is" and "as available", '
        'without warranty of any kind, express or implied — including '
        'fitness for a particular purpose and non-infringement. It may '
        'contain bugs, and data loss is possible.',
  ),
  TermsSection(
    '9. Limitation of liability',
    'To the maximum extent permitted by law, the developers and '
        'contributors are not liable for any damages or losses arising '
        'from your use of (or inability to use) the app — including '
        'content you or others access or publish, lost funds, lost '
        'data, or legal claims made against you.',
  ),
  TermsSection(
    '10. Indemnity',
    'You agree to indemnify and hold the developers and contributors '
        'harmless from any claims, damages, or expenses arising from '
        'your use of the app or your violation of these terms.',
  ),
  TermsSection(
    '11. Changes to these terms',
    'These terms may be updated in a future version of the app. When '
        'they change, you will be asked to accept the new terms before '
        'continuing to use the app.',
  ),
];
