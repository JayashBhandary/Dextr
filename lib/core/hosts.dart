/// Whether a host is one the machine can reach without leaving a trusted path.
///
/// Used to decide how loudly to talk about transport security. Connecting to a
/// database on this machine over plain TCP is normal and fine; doing it to a
/// host across a network the user does not control is the thing worth saying
/// out loud, and the two are told apart here rather than in each form.
library;

/// Whether [host] resolves somewhere the traffic never crosses an untrusted
/// network.
///
/// Deliberately conservative: anything this cannot positively identify as local
/// or private is treated as remote, because being wrong in that direction
/// produces a warning nobody needed rather than a silence somebody did.
bool isLocalOrPrivateHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;

  // A unix socket path or a named pipe never touches the network.
  if (h.startsWith('/') || h.startsWith(r'\\.\pipe')) return true;

  if (h == 'localhost' ||
      h == '::1' ||
      h == '[::1]' ||
      h.endsWith('.localhost') ||
      h.endsWith('.local')) {
    return true;
  }

  final octets = h.split('.');
  if (octets.length == 4) {
    final parts = octets.map(int.tryParse).toList();
    if (parts.every((p) => p != null && p >= 0 && p <= 255)) {
      final a = parts[0]!;
      final b = parts[1]!;
      // RFC 1918 private, RFC 5735 loopback, RFC 3927 link-local, and the
      // RFC 6598 shared address space carriers use for NAT.
      if (a == 127) return true;
      if (a == 10) return true;
      if (a == 192 && b == 168) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 169 && b == 254) return true;
      if (a == 100 && b >= 64 && b <= 127) return true;
    }
  }

  // IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
  final bare = h.startsWith('[') && h.endsWith(']')
      ? h.substring(1, h.length - 1)
      : h;
  if (bare.contains(':')) {
    if (bare.startsWith('fc') || bare.startsWith('fd')) return true;
    if (bare.startsWith('fe8') ||
        bare.startsWith('fe9') ||
        bare.startsWith('fea') ||
        bare.startsWith('feb')) {
      return true;
    }
  }

  return false;
}
