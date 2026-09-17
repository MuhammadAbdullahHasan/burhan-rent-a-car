import 'package:burhan_rent_a_car/auth/email_rate_limit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('no retry time until this device has used its share of the hour',
      () async {
    expect(await EmailRateLimit.retryAt(), isNull);
    await EmailRateLimit.recordSend();
    expect(await EmailRateLimit.retryAt(), isNull);
  });

  test(
      'after the hourly quota, the retry time is exactly one hour after '
      'the send that started the window', () async {
    await EmailRateLimit.recordSend();
    final first = DateTime.now().toUtc();
    await EmailRateLimit.recordSend();
    final retry = await EmailRateLimit.retryAt();
    expect(retry, isNotNull);
    final delta = retry!.difference(first.add(EmailRateLimit.window)).abs();
    expect(delta, lessThan(const Duration(seconds: 2)));
  });

  test('a per-request cool-down reply gives the exact seconds', () {
    expect(
      EmailRateLimit.fromMessage(
        'For security purposes, you can only request this after 42 seconds.',
      ),
      const Duration(seconds: 42),
    );
    expect(EmailRateLimit.fromMessage('email rate limit exceeded'), isNull);
  });

  test('remaining time reads as minutes and seconds', () {
    expect(formatRemaining(const Duration(minutes: 42, seconds: 7)),
        '42 min 07 s');
    expect(formatRemaining(const Duration(seconds: 9)), '9 s');
    expect(formatRemaining(const Duration(seconds: -5)), '0 s');
  });
}
