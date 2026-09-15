/// Supabase project connection details for Burhan Rent-A-Car.
///
/// The anon/publishable key is *meant* to be embedded in client code --
/// unlike a service-role key, it carries no privilege on its own. Every
/// table it can reach is protected by Postgres Row Level Security scoped to
/// `owner_id = auth.uid()` (see supabase_migration.sql), so committing this
/// value is standard practice, not a credential leak. Never put a
/// service-role key here or anywhere client-side.
const supabaseUrl = 'https://qaezjbadebwonreoggds.supabase.co';
const supabasePublishableKey = 'sb_publishable__fTN9ntFwaCAFSt83Zj0XQ_qT-HDmFW';
