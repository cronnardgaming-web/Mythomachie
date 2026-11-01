-- =====================================================================
-- CORRECTIF : « Could not choose the best candidate function » dans les statistiques
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-simulations.sql.
-- Supprime les anciennes versions des fonctions de statistiques, qui coexistaient avec la nouvelle.
-- =====================================================================
drop function if exists public.admin_stats_heros(int);
drop function if exists public.admin_stats_heros(int, boolean);
drop function if exists public.admin_stats_cartes(int);
drop function if exists public.admin_stats_cartes(int, boolean);
-- Le serveur relit immédiatement la liste des fonctions
notify pgrst, 'reload schema';
