import 'dart:io';

/// Whether [address] is on the public internet.
///
/// Traffic a router redirects here was on its way out to the internet, so a
/// relay to anything else is never needed, and refusing it keeps the proxy
/// from being used to reach this machine or the rest of the LAN.
bool isPublicAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224) return false;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return false;
    if (b[0] == 192 && b[1] == 168) return false;
    if (b[0] == 169 && b[1] == 254) return false;
    // Carrier-grade NAT, 100.64.0.0/10.
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return false;
    return true;
  }
  if (address.type == InternetAddressType.IPv6) {
    if (b.every((byte) => byte == 0)) return false;
    // Unique local, fc00::/7.
    if (b[0] & 0xfe == 0xfc) return false;
    // IPv4-mapped, ::ffff:a.b.c.d.
    if (b.take(10).every((byte) => byte == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff) {
      return isPublicAddress(InternetAddress.fromRawAddress(b.sublist(12)));
    }
    return true;
  }
  return false;
}

/// Bilibili's audio streams carry ids 302xx (30216, 30232, 30280, 30250…).
bool isAudioTrack(String target) =>
    RegExp(r'-302\d\d\.m4s(\?|$)').hasMatch(target);
