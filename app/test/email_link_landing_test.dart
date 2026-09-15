import 'package:burhan_rent_a_car/auth/email_link_landing.dart';
import 'package:flutter_test/flutter_test.dart';

/// The URL fragment Supabase leaves behind when an emailed link is clicked.
void main() {
  const token = 'access_token=abc&refresh_token=def&expires_in=3600&token_type=bearer';

  test('recognises each link type', () {
    expect(parseEmailLinkType('$token&type=signup'), EmailLinkType.signup);
    expect(parseEmailLinkType('$token&type=magiclink'), EmailLinkType.magiclink);
    expect(parseEmailLinkType('$token&type=recovery'), EmailLinkType.recovery);
    // A code-style OTP email's link lands as type=email; same proof.
    expect(parseEmailLinkType('$token&type=email'), EmailLinkType.magiclink);
  });

  test('ignores a normal page load', () {
    expect(parseEmailLinkType(''), isNull);
    expect(parseEmailLinkType('some-route'), isNull);
  });

  test('ignores a fragment with a type but no session tokens', () {
    // Never treat a bare "?type=magiclink" as verified -- no session came
    // with it, so nothing was actually proven.
    expect(parseEmailLinkType('type=magiclink'), isNull);
  });

  test('ignores unknown types', () {
    expect(parseEmailLinkType('$token&type=invite'), isNull);
    expect(parseEmailLinkType(token), isNull);
  });
}
