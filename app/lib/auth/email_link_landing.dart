/// What kind of emailed link, if any, the app was just opened from.
///
/// When a Supabase auth email link is clicked it redirects to the project's
/// Site URL with the new session in the URL fragment, e.g.
/// `#access_token=…&type=magiclink`. The SDK consumes the tokens; this
/// records the `type` first, because the app treats each kind differently:
/// a confirmation or magic link proves inbox access (second factor done),
/// while a recovery link must go to the set-new-password screen.
enum EmailLinkType { signup, magiclink, recovery }

EmailLinkType? parseEmailLinkType(String fragment) {
  if (!fragment.contains('access_token=')) return null;
  final params = Uri.splitQueryString(fragment);
  return switch (params['type']) {
    'signup' => EmailLinkType.signup,
    'magiclink' => EmailLinkType.magiclink,
    'recovery' => EmailLinkType.recovery,
    // 'email' is what a code-style OTP link carries when the user clicks it
    // instead of typing the code -- same proof of inbox access.
    'email' => EmailLinkType.magiclink,
    _ => null,
  };
}
