-- Accès à l'administration : à exécuter une fois dans Supabase (SQL Editor, puis Run).
-- Permet au jeu de savoir si un administrateur existe déjà, sans révéler qui il est.
create or replace function public.admin_existe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins)
$$;
grant execute on function public.admin_existe() to anon, authenticated;

-- Personne ne peut s'ajouter lui-même comme administrateur depuis le jeu :
-- la table admins n'accepte aucune écriture venant des joueurs.
revoke insert, update, delete on public.admins from anon, authenticated;
