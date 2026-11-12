-- =====================================================================
-- RÈGLES DE BLOCAGE DES PARTIES : durée minimale 75 secondes, 60 parties par heure au maximum
-- À exécuter une fois dans Supabase (SQL Editor, puis Run). Il peut être relancé sans risque.
-- =====================================================================
update public.economie
   set reglages = coalesce(reglages, '{}'::jsonb) || jsonb_build_object('duree_min_partie', 75, 'parties_par_heure', 60)
 where id = 1;

-- Vérification : les deux valeurs doivent s’afficher (75 et 60)
select reglages->'duree_min_partie' as duree_min_secondes, reglages->'parties_par_heure' as parties_par_heure from public.economie where id = 1;
