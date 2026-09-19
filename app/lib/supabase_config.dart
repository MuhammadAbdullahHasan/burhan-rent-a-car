/// Supabase project connection details for Burhan Rent-A-Car.
///
/// The anon/publishable key is *meant* to be embedded in client code --
/// unlike a service-role key, it carries no privilege on its own. Every
/// table it can reach is protected by Postgres Row Level Security scoped to
/// business membership (see supabase_migration.sql), so committing this
/// value is standard practice, not a credential leak. Never put a
/// service-role key here or anywhere client-side.
const supabaseUrl = 'https://oxkebeulfbgcxfaattna.supabase.co';
const supabasePublishableKey = 'sb_publishable_YVCUYvjXYsObRg6vZmxybQ_fdg6CpXZ';

/// The business's folder in the private Storage buckets (`agreements`,
/// `backups`). One business, two logins: the owner's and the developer's.
/// Both see the same records and the same files, so the folder is fixed
/// rather than named after whoever is signed in. The value is the id of
/// the account that first loaded the archive -- kept so nothing had to
/// move. Only members of the business can read or write inside it (the
/// storage policies check membership, not the folder name).
const businessFolder = 'f9c626da-b85d-412c-aab1-368c09b94a02';
