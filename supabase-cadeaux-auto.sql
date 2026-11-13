-- =====================================================================
-- CADEAUX AUTOMATIQUES : un message avec cadeau dès qu’un joueur atteint un nombre de parties
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-social.sql.
-- Les parties comptées sont celles contre l’ordinateur, en ligne et en 2 contre 2. Chaque palier n’est envoyé
-- qu’une fois par joueur. Dans le texte, {pseudo} et {parties} sont remplacés automatiquement.
-- =====================================================================
create table if not exists public.paliers_parties (
  id bigint generated always as identity primary key,
  seuil int not null check (seuil > 0),
  titre text not null,
  texte text not null default '',
  cadeau jsonb,
  actif boolean not null default true
);
alter table public.paliers_parties enable row level security;

create table if not exists public.envois_paliers (
  joueur uuid not null references auth.users(id) on delete cascade,
  palier bigint not null references public.paliers_parties(id) on delete cascade,
  envoye timestamptz not null default now(),
  primary key (joueur, palier)
);
alter table public.envois_paliers enable row level security;

-- Envoie à un joueur les paliers atteints qu’il n’a pas encore reçus ; renvoie le nombre de messages envoyés
create or replace function public.envoyer_paliers_parties(u uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int; p paliers_parties; pseudo text; envoyes int := 0;
begin
  select count(*) into n from parties_jouees where joueur = u and mode in ('ia', 'enligne', '2v2');
  select coalesce(pr.pseudo, 'aventurier') into pseudo from profils pr where pr.id = u;
  for p in select * from paliers_parties pp where pp.actif and pp.seuil <= n
             and not exists (select 1 from envois_paliers e where e.joueur = u and e.palier = pp.id) order by pp.seuil loop
    insert into envois_paliers (joueur, palier) values (u, p.id) on conflict do nothing;
    if found then
      insert into messages (joueur, titre, texte, cadeau)
      values (u, replace(replace(p.titre, '{pseudo}', pseudo), '{parties}', p.seuil::text),
                 replace(replace(p.texte, '{pseudo}', pseudo), '{parties}', p.seuil::text),
                 case when p.cadeau is null or p.cadeau = '{}'::jsonb then null else p.cadeau end);
      envoyes := envoyes + 1;
    end if;
  end loop;
  return envoyes;
end $$;
revoke execute on function public.envoyer_paliers_parties(uuid) from public, anon, authenticated;

-- À chaque partie enregistrée pour un joueur
create or replace function public.declencher_paliers_parties() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.joueur is not null and new.mode in ('ia', 'enligne', '2v2') then perform envoyer_paliers_parties(new.joueur); end if;
  return new;
end $$;
drop trigger if exists parties_paliers on public.parties_jouees;
create trigger parties_paliers after insert on public.parties_jouees for each row execute function public.declencher_paliers_parties();

-- Administration : lire les paliers (avec le nombre de joueurs déjà servis)
create or replace function public.admin_paliers_parties() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'seuil', p.seuil, 'titre', p.titre, 'texte', p.texte, 'cadeau', p.cadeau, 'actif', p.actif,
            'envois', (select count(*) from envois_paliers e where e.palier = p.id),
            'eligibles', (select count(*) from (select joueur from parties_jouees where joueur is not null and mode in ('ia', 'enligne', '2v2')
                                                group by joueur having count(*) >= p.seuil) x)) order by p.seuil), '[]'::jsonb)
          from paliers_parties p);
end $$;
grant execute on function public.admin_paliers_parties() to authenticated;

-- Administration : enregistrer la liste des paliers (ceux absents de la liste sont supprimés)
create or replace function public.admin_maj_paliers_parties(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare x jsonb; garde bigint[] := '{}'; i bigint;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  for x in select v from jsonb_array_elements(coalesce(p, '[]'::jsonb)) v loop
    if coalesce((x->>'seuil')::int, 0) <= 0 or coalesce(trim(x->>'titre'), '') = '' then raise exception 'Chaque palier doit avoir un nombre de parties et un titre.'; end if;
    if (x->>'id') is not null and exists (select 1 from paliers_parties where id = (x->>'id')::bigint) then
      update paliers_parties set seuil = (x->>'seuil')::int, titre = left(x->>'titre', 120), texte = left(coalesce(x->>'texte', ''), 4000),
        cadeau = nullif(x->'cadeau', '{}'::jsonb), actif = coalesce((x->>'actif')::boolean, true) where id = (x->>'id')::bigint returning id into i;
    else
      insert into paliers_parties (seuil, titre, texte, cadeau, actif) values ((x->>'seuil')::int, left(x->>'titre', 120), left(coalesce(x->>'texte', ''), 4000),
        nullif(x->'cadeau', '{}'::jsonb), coalesce((x->>'actif')::boolean, true)) returning id into i;
    end if;
    garde := garde || i;
  end loop;
  delete from paliers_parties where not (id = any(garde));
  return cardinality(garde);
end $$;
grant execute on function public.admin_maj_paliers_parties(jsonb) to authenticated;

-- Administration : servir tout de suite les joueurs qui ont déjà atteint des paliers
create or replace function public.admin_appliquer_paliers_parties() returns int
language plpgsql security definer set search_path = public as $$
declare u uuid; total int := 0;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  for u in select distinct joueur from parties_jouees where joueur is not null and mode in ('ia', 'enligne', '2v2') loop
    total := total + envoyer_paliers_parties(u);
  end loop;
  return total;
end $$;
grant execute on function public.admin_appliquer_paliers_parties() to authenticated;
