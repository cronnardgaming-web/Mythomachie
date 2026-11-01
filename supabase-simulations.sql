-- =====================================================================
-- PARTIES SIMULÉES : import dans les statistiques, compteur séparé, filtre
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après les autres scripts.
-- Les parties simulées n’ont pas de joueur : elles ne comptent ni pour les quêtes, ni pour les
-- trophées, ni pour la saison, ni pour le classement, et ne déclenchent pas d’alerte.
-- =====================================================================

-- Import : liste de parties {t: tours, v: 0 | 1 | null (égalité), c: [camp0, camp1]}
create or replace function public.admin_importer_simulations(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare g jsonb; i int; c jsonb; idp text; n int := 0;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 2000 then raise exception 'Envoyez au plus 2 000 parties à la fois.'; end if;
  for g in select x from jsonb_array_elements(p) x loop
    idp := 'sim-' || md5(random()::text || clock_timestamp()::text);
    for i in 0..1 loop
      c := g->'c'->i;
      insert into parties_jouees (id_partie, place, cote, joueur, mode, victoire, egalite, tours, heros, heros_adverse,
                                  degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees, combos, equipements, bannis, palier, pv_fin)
      values (idp, i, 'simulation', null, 'simulation', (g->>'v') is not null and (g->>'v')::int = i, (g->>'v') is null,
              least(greatest(coalesce((g->>'t')::int, 0), 0), 400), left(c->>'heros', 30), left(g->'c'->(1 - i)->>'heros', 30),
              borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300), borne(c->>'sorts', 400),
              borne(c->>'achats', 300), borne(c->>'pouvoirs', 60),
              case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end,
              case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end,
              borne(c->>'combos', 300), borne(c->>'equipements', 100), borne(c->>'bannis', 100),
              least(greatest(coalesce((c->>'palier')::int, 0), 0), 2), least(greatest(coalesce((c->>'pv_fin')::int, 0), -200), 500));
    end loop;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.admin_importer_simulations(jsonb) to authenticated;

create or replace function public.admin_effacer_simulations() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  delete from parties_jouees where mode = 'simulation';
  get diagnostics n = row_count;
  return n / 2;
end $$;
grant execute on function public.admin_effacer_simulations() to authenticated;

create or replace function public.admin_nb_simulations() returns int
language sql stable security definer set search_path = public as $$
  select case when est_admin() then (select count(distinct id_partie)::int from parties_jouees where mode = 'simulation') else 0 end
$$;
grant execute on function public.admin_nb_simulations() to authenticated;

-- Statistiques des héros et des cartes : simulations incluses ou non
drop function if exists public.admin_stats_heros(int, boolean);
create or replace function public.admin_stats_heros(p_jours int default 365, p_sans_invites boolean default false, p_simulations boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (with p as (select * from parties_jouees
                     where cree > now() - make_interval(days => p_jours)
                       and (p_simulations or mode <> 'simulation')
                       and (not p_sans_invites or id_partie not in (select parties_avec_invite())))
  select jsonb_build_object(
    'heros', (select coalesce(jsonb_agg(jsonb_build_object('heros', heros, 'parties', n, 'victoires', v, 'tours', t)), '[]'::jsonb) from (
       select heros, count(*) n, count(*) filter (where victoire) v, round(avg(tours), 1) t from p where heros is not null group by heros) x),
    'duels', (select coalesce(jsonb_agg(jsonb_build_object('heros', heros, 'contre', heros_adverse, 'parties', n, 'victoires', v)), '[]'::jsonb) from (
       select heros, heros_adverse, count(*) n, count(*) filter (where victoire) v from p
       where heros is not null and heros_adverse is not null group by heros, heros_adverse) y)));
end $$;
grant execute on function public.admin_stats_heros(int, boolean, boolean) to authenticated;

drop function if exists public.admin_stats_cartes(int, boolean);
create or replace function public.admin_stats_cartes(p_jours int default 30, p_sans_invites boolean default false, p_simulations boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (with p as (select * from parties_jouees
                     where cree > now() - make_interval(days => p_jours)
                       and (p_simulations or mode <> 'simulation')
                       and (not p_sans_invites or id_partie not in (select parties_avec_invite()))),
    j as (select e.key carte, sum(e.value::numeric)::int fois, count(*) parties, count(*) filter (where p.victoire) victoires
          from p, jsonb_each_text(p.jouees) e group by e.key),
    a as (select e.key carte, sum(e.value::numeric)::int fois from p, jsonb_each_text(p.achetees) e group by e.key)
    select coalesce(jsonb_agg(jsonb_build_object('carte', c.carte, 'jouee', coalesce(j.fois, 0), 'parties', coalesce(j.parties, 0),
                                                 'victoires', coalesce(j.victoires, 0), 'achetee', coalesce(a.fois, 0))), '[]'::jsonb)
    from catalogue c left join j on j.carte = c.carte left join a on a.carte = c.carte
    where c.achetable);
end $$;
grant execute on function public.admin_stats_cartes(int, boolean, boolean) to authenticated;

-- Vue d’ensemble : les parties simulées sont comptées à part
create or replace view public.parties_jouees_reelles with (security_invoker = true) as
  select * from public.parties_jouees where mode <> 'simulation';
revoke all on public.parties_jouees_reelles from anon, authenticated;

create or replace function public.admin_resume() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return jsonb_build_object(
    'joueurs', (select count(*) from profils),
    'comptes', (select count(*) from profils p join auth.users u on u.id = p.id where u.email is not null),
    'en_ligne', (select count(*) from profils where derniere_vue > now() - interval '2 minutes'),
    'actifs_7j', (select count(*) from profils where derniere_vue > now() - interval '7 days'),
    'parties', (select count(distinct id_partie) from parties_jouees_reelles),
    'parties_24h', (select count(distinct id_partie) from parties_jouees_reelles where cree > now() - interval '24 hours'),
    'parties_7j', (select count(distinct id_partie) from parties_jouees_reelles where cree > now() - interval '7 days'),
    'parties_ia', (select count(distinct id_partie) from parties_jouees_reelles where mode = 'ia'),
    'parties_en_ligne', (select count(distinct id_partie) from parties_jouees_reelles where mode = 'enligne'),
    'parties_duo', (select count(distinct id_partie) from parties_jouees_reelles where mode = 'duo'),
    'ordinateur_parties', (select count(*) from parties_jouees_reelles where cote = 'ordinateur'),
    'ordinateur_victoires', (select count(*) from parties_jouees_reelles where cote = 'ordinateur' and victoire),
    'camps', (select count(*) from parties_jouees_reelles),
    'camps_victoires', (select count(*) from parties_jouees_reelles where victoire),
    'tours_moyens', (select round(avg(tours), 1) from parties_jouees_reelles),
    'duree_moyenne_s', (select round(avg(duree_s)) from parties_jouees_reelles),
    'parties_simulees', (select count(distinct id_partie) from parties_jouees where mode = 'simulation')
  );
end $$;
