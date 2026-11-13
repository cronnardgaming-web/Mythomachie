-- =====================================================================
-- JOUEURS EN LIGNE : nombre affiché sur l’accueil (joueurs actifs ces 2 dernières minutes)
-- À exécuter une fois dans Supabase (SQL Editor, puis Run).
-- =====================================================================
create or replace function public.joueurs_en_ligne() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from profils where derniere_vue > now() - interval '2 minutes'
$$;
grant execute on function public.joueurs_en_ligne() to authenticated;
