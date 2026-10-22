-- =====================================================================
-- STATISTIQUES COMPLÈTES : les deux camps de chaque partie
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-stats.sql.
-- ATTENTION : ce script REMET À ZÉRO toutes les parties enregistrées.
-- =====================================================================

-- 1. Remise à zéro de l’historique des parties
truncate table public.parties_jouees restart identity;

-- 2. Une ligne par camp : le joueur, l’ordinateur, l’invité en ligne, ou un camp local (même écran)
alter table public.parties_jouees alter column joueur drop not null;
alter table public.parties_jouees add column if not exists id_partie text;
alter table public.parties_jouees add column if not exists place smallint;
alter table public.parties_jouees add column if not exists cote text not null default 'joueur';
alter table public.parties_jouees add column if not exists egalite boolean not null default false;
alter table public.parties_jouees add column if not exists enregistre_par uuid;
create unique index if not exists parties_jouees_unique on public.parties_jouees (id_partie, place);

-- 3. Enregistrement d’une partie complète, une seule fois, avec ses deux camps
create or replace function public.enregistrer_duel(d jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  m text := left(coalesce(d->>'mode', ''), 12);
  idp text := left(d->>'id_partie', 60);
  v int := case when d->>'vainqueur' in ('0', '1') then (d->>'vainqueur')::int else null end;
  c jsonb; i int; typ text; j uuid;
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  if idp is null or length(idp) < 6 then raise exception 'Partie sans identifiant.'; end if;
  if pg_column_size(d) > 60000 then raise exception 'Données de partie trop volumineuses.'; end if;
  if m not in ('ia', 'enligne', 'duo') then raise exception 'Mode de partie inconnu.'; end if;
  for i in 0..1 loop
    c := d->'cotes'->i;
    if c is null or jsonb_typeof(c) <> 'object' then raise exception 'Il manque un des deux camps.'; end if;
    if m = 'ia' then
      typ := case when i = 0 then 'joueur' else 'ordinateur' end;
      j := case when i = 0 then u else null end;
    elsif m = 'duo' then
      typ := 'local'; j := null;
    else
      typ := case when i = 0 then 'joueur' else 'invite' end;
      j := case when i = 0 then u
                when c->>'joueur' ~ '^[0-9a-fA-F-]{36}$' then (select id from profils where id = (c->>'joueur')::uuid)
                else null end;
    end if;
    insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s,
                                heros, heros_adverse, degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees)
    values (idp, i, typ, j, u, m, v is not null and v = i, v is null,
            borne(d->>'tours', 1000), borne(d->>'duree_s', 86400),
            left(c->>'heros', 30), left(d->'cotes'->(1-i)->>'heros', 30),
            borne(c->>'degats', 100000), borne(c->>'soins', 100000), borne(c->>'creatures', 10000),
            borne(c->>'sorts', 10000), borne(c->>'achats', 10000), borne(c->>'pouvoirs', 1000),
            case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end,
            case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end)
    on conflict (id_partie, place) do nothing;
  end loop;
end $$;

-- 4. L’ancienne fonction ne compte plus rien (évite les doublons venant d’une page pas encore mise à jour)
create or replace function public.enregistrer_partie(d jsonb) returns void
language plpgsql security definer set search_path = public as $$ begin return; end $$;

-- 5. Résumé de l’administrateur : parties comptées une fois, et résultats de l’ordinateur
create or replace function public.admin_resume() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return jsonb_build_object(
    'joueurs', (select count(*) from profils),
    'comptes', (select count(*) from profils p join auth.users u on u.id = p.id where u.email is not null),
    'en_ligne', (select count(*) from profils where derniere_vue > now() - interval '2 minutes'),
    'actifs_7j', (select count(*) from profils where derniere_vue > now() - interval '7 days'),
    'parties', (select count(distinct id_partie) from parties_jouees),
    'parties_24h', (select count(distinct id_partie) from parties_jouees where cree > now() - interval '24 hours'),
    'parties_7j', (select count(distinct id_partie) from parties_jouees where cree > now() - interval '7 days'),
    'parties_ia', (select count(distinct id_partie) from parties_jouees where mode = 'ia'),
    'parties_en_ligne', (select count(distinct id_partie) from parties_jouees where mode = 'enligne'),
    'parties_duo', (select count(distinct id_partie) from parties_jouees where mode = 'duo'),
    'ordinateur_parties', (select count(*) from parties_jouees where cote = 'ordinateur'),
    'ordinateur_victoires', (select count(*) from parties_jouees where cote = 'ordinateur' and victoire),
    'camps', (select count(*) from parties_jouees),
    'camps_victoires', (select count(*) from parties_jouees where victoire),
    'tours_moyens', (select round(avg(tours), 1) from parties_jouees),
    'duree_moyenne_s', (select round(avg(duree_s)) from parties_jouees)
  );
end $$;
