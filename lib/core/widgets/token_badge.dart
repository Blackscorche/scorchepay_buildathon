import 'package:flutter/material.dart';

/// Circular crypto-asset badge. Shows the coin's real logo (from
/// CoinGecko) when [logoUrl] is available; otherwise falls back to a
/// soft tint of the coin's brand color plus its ticker glyph — the same
/// fallback pattern real wallet apps (Rainbow, Phantom, Coinbase Wallet)
/// use for any token that doesn't have a logo loaded yet.
class TokenBadge extends StatelessWidget {
  const TokenBadge({
    super.key,
    required this.glyph,
    required this.color,
    this.size = 38,
    this.logoUrl,
  });

  final String glyph;
  final Color color;
  final double size;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final url = logoUrl;
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: url == null || url.isEmpty
            ? _glyphFallback()
            : Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _glyphFallback(),
                errorBuilder: (context, error, stackTrace) => _glyphFallback(),
              ),
      ),
    );
  }

  Widget _glyphFallback() {
    return Text(
      glyph,
      style: TextStyle(
          fontSize: size * 0.42, fontWeight: FontWeight.w800, color: color),
    );
  }
}
