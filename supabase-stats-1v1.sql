-- =====================================================================
-- STATISTIQUES DU PROFIL : 1 CONTRE 1
-- Parties contre l’ordinateur et contre un joueur (hors 2 contre 2 et hors parties à deux sur le même écran).
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-stats.sql. Il peut être relancé sans risque.
-- =====================================================================
create or replace function public.mes_stats_1v1() returns jsonb
language sql stable security definer set search_path = public as $$
  with p as (select * from parties_jouees where joueur = auth.uid() and mode in ('ia', 'enligne'))
  select jsonb_build_object(
    'parties', (select count(*) from p), 'victoires', (select count(*) from p where victoire),
    'ordi', jsonb_build_object('parties', (select count(*) from p where mode = 'ia'), 'victoires', (select count(*) from p where mode = 'ia' and victoire)),
    'joueurs', jsonb_build_object('parties', (select count(*) from p where mode = 'enligne'), 'victoires', (select count(*) from p where mode = 'enligne' and victoire)),
    'degats', (select coalesce(sum(degats), 0) from p), 'soins', (select coalesce(sum(soins), 0) from p),
    'creatures', (select coalesce(sum(creatures), 0) from p), 'pouvoirs', (select coalesce(sum(pouvoirs), 0) from p),
    'serie_max', (select coalesce(max(n), 0) from (
        select count(*) n from (select victoire, sum(case when victoire then 0 else 1 end) over (order by cree, id) g from p) s
        where victoire group by g) t),
    'par_heros', (select coalesce(jsonb_object_agg(heros, jsonb_build_object('parties', n, 'victoires', v)), '{}'::jsonb)
                  from (select heros, count(*) n, count(*) filter (where victoire) v from p where heros is not null group by heros) x))
$$;
grant execute on function public.mes_stats_1v1() to authenticated;
