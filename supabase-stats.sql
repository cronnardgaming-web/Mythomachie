-- =====================================================================
-- STATISTIQUES, PRÉSENCE, PSEUDOS
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-admin.sql.
-- =====================================================================

-- ---------- Pseudo et présence (dernière visite, écran affiché)
alter table public.profils add column if not exists pseudo text;
alter table public.profils add column if not exists derniere_vue timestamptz;
alter table public.profils add column if not exists ecran text;
create unique index if not exists profils_pseudo_unique on public.profils (lower(pseudo));

create or replace function public.definir_pseudo(p text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'));
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if v !~ '^[[:alnum:]À-ÿ _-]{3,20}$' then
    raise exception 'Le pseudo doit faire de 3 à 20 caractères : lettres, chiffres, espaces, tirets ou soulignés.';
  end if;
  begin
    update profils set pseudo = v where id = auth.uid();
  exception when unique_violation then
    raise exception 'Ce pseudo est déjà pris : choisissez-en un autre.';
  end;
  return v;
end $$;

create or replace function public.signaler(e text) returns void
language sql security definer set search_path = public as $$
  update profils set derniere_vue = now(), ecran = left(coalesce(e, ''), 30) where id = auth.uid()
$$;

-- ---------- Historique des parties (une ligne par joueur et par partie)
create table if not exists public.parties_jouees (
  id bigint generated always as identity primary key,
  joueur uuid not null references auth.users(id) on delete cascade,
  mode text not null,
  victoire boolean not null,
  tours int, duree_s int,
  heros text, heros_adverse text,
  degats int not null default 0, soins int not null default 0,
  creatures int not null default 0, sorts int not null default 0,
  achats int not null default 0, pouvoirs int not null default 0,
  jouees jsonb, achetees jsonb,
  cree timestamptz not null default now()
);
create index if not exists parties_jouees_joueur on public.parties_jouees (joueur, cree);
create index if not exists parties_jouees_cree on public.parties_jouees (cree);
alter table public.parties_jouees enable row level security;
drop policy if exists parties_jouees_lit on public.parties_jouees;
create policy parties_jouees_lit on public.parties_jouees for select to authenticated using (joueur = auth.uid());

create or replace function public.borne(v text, maxi int) returns int
language sql immutable as $$ select greatest(0, least(maxi, coalesce(nullif(v, '')::numeric, 0)))::int $$;

create or replace function public.enregistrer_partie(d jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if pg_column_size(d) > 30000 then raise exception 'Données de partie trop volumineuses.'; end if;
  insert into parties_jouees (joueur, mode, victoire, tours, duree_s, heros, heros_adverse,
                              degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees)
  values (auth.uid(), left(coalesce(d->>'mode', '?'), 12), coalesce((d->>'victoire')::boolean, false),
          borne(d->>'tours', 1000), borne(d->>'duree_s', 86400), left(d->>'heros', 30), left(d->>'heros_adverse', 30),
          borne(d->>'degats', 100000), borne(d->>'soins', 100000), borne(d->>'creatures', 10000),
          borne(d->>'sorts', 10000), borne(d->>'achats', 10000), borne(d->>'pouvoirs', 1000),
          case when jsonb_typeof(d->'jouees') = 'object' then d->'jouees' else '{}'::jsonb end,
          case when jsonb_typeof(d->'achetees') = 'object' then d->'achetees' else '{}'::jsonb end);
end $$;

-- ---------- Statistiques d'un joueur (pour son profil)
create or replace function public.mes_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  with p as (select * from parties_jouees where joueur = auth.uid())
  select jsonb_build_object(
    'parties', (select count(*) from p),
    'victoires', (select count(*) from p where victoire),
    'degats', (select coalesce(sum(degats), 0) from p),
    'soins', (select coalesce(sum(soins), 0) from p),
    'creatures', (select coalesce(sum(creatures), 0) from p),
    'sorts', (select coalesce(sum(sorts), 0) from p),
    'achats', (select coalesce(sum(achats), 0) from p),
    'pouvoirs', (select coalesce(sum(pouvoirs), 0) from p),
    'en_ligne', (select count(*) from p where mode = 'enligne'),
    'victoires_en_ligne', (select count(*) from p where mode = 'enligne' and victoire),
    'serie_max', (select coalesce(max(n), 0) from (
        select count(*) n from (select victoire, sum(case when victoire then 0 else 1 end) over (order by cree, id) g from p) s
        where victoire group by g) t),
    'par_heros', (select coalesce(jsonb_object_agg(heros, jsonb_build_object('parties', n, 'victoires', v)), '{}'::jsonb)
                  from (select heros, count(*) n, count(*) filter (where victoire) v from p where heros is not null group by heros) x)
  )
$$;

-- ---------- Statistiques réservées à l'administrateur
create or replace function public.admin_resume() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return jsonb_build_object(
    'joueurs', (select count(*) from profils),
    'comptes', (select count(*) from profils p join auth.users u on u.id = p.id where u.email is not null),
    'en_ligne', (select count(*) from profils where derniere_vue > now() - interval '2 minutes'),
    'actifs_7j', (select count(*) from profils where derniere_vue > now() - interval '7 days'),
    'parties', (select count(*) from parties_jouees),
    'parties_24h', (select count(*) from parties_jouees where cree > now() - interval '24 hours'),
    'parties_7j', (select count(*) from parties_jouees where cree > now() - interval '7 days'),
    'parties_ia', (select count(*) from parties_jouees where mode = 'ia'),
    'parties_en_ligne', (select count(*) from parties_jouees where mode = 'enligne'),
    'tours_moyens', (select round(avg(tours), 1) from parties_jouees),
    'duree_moyenne_s', (select round(avg(duree_s)) from parties_jouees)
  );
end $$;

create or replace function public.admin_joueurs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.derniere_vue desc nulls last), '[]'::jsonb) from (
    select p.id, p.pseudo, u.email, p.cree, p.derniere_vue, p.ecran, p.pieces_or, p.encre,
           (select count(*) from parties_jouees j where j.joueur = p.id) parties,
           (select count(*) from parties_jouees j where j.joueur = p.id and j.victoire) victoires,
           (select coalesce(sum(nb), 0) from collection c where c.joueur = p.id) cartes
    from profils p left join auth.users u on u.id = p.id) x);
end $$;

create or replace function public.admin_stats_heros(p_jours int default 365) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return jsonb_build_object(
    'heros', (select coalesce(jsonb_agg(jsonb_build_object('heros', heros, 'parties', n, 'victoires', v, 'tours', t)), '[]'::jsonb) from (
       select heros, count(*) n, count(*) filter (where victoire) v, round(avg(tours), 1) t
       from parties_jouees where heros is not null and cree > now() - make_interval(days => p_jours) group by heros) x),
    'duels', (select coalesce(jsonb_agg(jsonb_build_object('heros', heros, 'contre', heros_adverse, 'parties', n, 'victoires', v)), '[]'::jsonb) from (
       select heros, heros_adverse, count(*) n, count(*) filter (where victoire) v
       from parties_jouees where heros is not null and heros_adverse is not null and cree > now() - make_interval(days => p_jours)
       group by heros, heros_adverse) y)
  );
end $$;

create or replace function public.admin_stats_cartes(p_jours int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (with p as (select * from parties_jouees where cree > now() - make_interval(days => p_jours)),
    j as (select e.key carte, sum(e.value::numeric)::int fois, count(*) parties, count(*) filter (where p.victoire) victoires
          from p, jsonb_each_text(p.jouees) e group by e.key),
    a as (select e.key carte, sum(e.value::numeric)::int fois from p, jsonb_each_text(p.achetees) e group by e.key)
    select coalesce(jsonb_agg(jsonb_build_object('carte', c.carte, 'jouee', coalesce(j.fois, 0), 'parties', coalesce(j.parties, 0),
                                                 'victoires', coalesce(j.victoires, 0), 'achetee', coalesce(a.fois, 0))), '[]'::jsonb)
    from catalogue c left join j on j.carte = c.carte left join a on a.carte = c.carte
    where c.achetable);
end $$;

revoke execute on function public.borne(text, int) from public, anon;
