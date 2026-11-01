-- =====================================================================
-- SOCIAL : amis et défis, boîte aux lettres (messages et cadeaux), notes de mise à jour
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après les autres scripts.
-- =====================================================================

-- ---------- Amis
create table if not exists public.amities (
  de uuid not null references auth.users(id) on delete cascade,
  vers uuid not null references auth.users(id) on delete cascade,
  statut text not null default 'attente' check (statut in ('attente', 'accepte')),
  cree timestamptz not null default now(),
  primary key (de, vers)
);
alter table public.amities enable row level security;

create or replace function public.chercher_joueurs(p_texte text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'pseudo', pseudo, 'elo', elo, 'titre', titre) order by lower(pseudo)), '[]'::jsonb)
  from (select id, pseudo, elo, titre from profils, (select replace(replace(replace(trim(coalesce(p_texte, '')), '\', ''), '%', ''), '_', '') t) n
        where pseudo is not null and id <> auth.uid() and length(n.t) >= 2
          and lower(pseudo) like lower(n.t) || '%'
        order by lower(pseudo) limit 10) x
$$;
grant execute on function public.chercher_joueurs(text) to authenticated;

create or replace function public.mes_amis() returns jsonb
language sql stable security definer set search_path = public as $$
  with u as (select auth.uid() id),
  fiche as (select p.id, jsonb_build_object('id', p.id, 'pseudo', coalesce(p.pseudo, 'Joueur'), 'elo', p.elo, 'titre', p.titre,
                   'en_ligne', p.derniere_vue > now() - interval '2 minutes') f from profils p)
  select jsonb_build_object(
    'amis', (select coalesce(jsonb_agg(f.f order by (f.f->>'en_ligne')::boolean desc, f.f->>'pseudo'), '[]'::jsonb) from amities a join fiche f
             on f.id = case when a.de = (select id from u) then a.vers else a.de end
             where a.statut = 'accepte' and (select id from u) in (a.de, a.vers)),
    'recues', (select coalesce(jsonb_agg(f.f), '[]'::jsonb) from amities a join fiche f on f.id = a.de where a.vers = (select id from u) and a.statut = 'attente'),
    'envoyees', (select coalesce(jsonb_agg(f.f), '[]'::jsonb) from amities a join fiche f on f.id = a.vers where a.de = (select id from u) and a.statut = 'attente'),
    'recents', (select coalesce(jsonb_agg(f.f), '[]'::jsonb) from (
        select distinct on (adv) adv, cree from (
          select case when t.hote = (select id from u) then t.invite else t.hote end adv, t.cree from tickets_partie t
          where t.mode = 'enligne' and t.invite is not null and (select id from u) in (t.hote, t.invite)) r
        where adv is not null order by adv, cree desc) r2
      join fiche f on f.id = r2.adv
      where not exists (select 1 from amities a where (a.de = (select id from u) and a.vers = r2.adv) or (a.vers = (select id from u) and a.de = r2.adv))
      limit 10))
$$;
grant execute on function public.mes_amis() to authenticated;

create or replace function public.demander_ami(p_joueur uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null or p_joueur is null or p_joueur = u then return jsonb_build_object('erreur', 'Demande impossible.'); end if;
  if not exists (select 1 from profils where id = p_joueur) then return jsonb_build_object('erreur', 'Joueur introuvable.'); end if;
  if exists (select 1 from amities where (de = u and vers = p_joueur) or (de = p_joueur and vers = u and statut = 'accepte')) then
    return jsonb_build_object('erreur', 'Demande déjà envoyée ou déjà amis.');
  end if;
  -- Demande croisée : l’amitié est conclue
  if exists (select 1 from amities where de = p_joueur and vers = u and statut = 'attente') then
    update amities set statut = 'accepte' where de = p_joueur and vers = u;
    return jsonb_build_object('ok', true, 'amis', true);
  end if;
  if (select count(*) from amities where de = u and statut = 'attente') >= 30 then return jsonb_build_object('erreur', 'Trop de demandes en attente.'); end if;
  insert into amities (de, vers) values (u, p_joueur);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.demander_ami(uuid) to authenticated;

create or replace function public.repondre_ami(p_joueur uuid, p_accepter boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_accepter then update amities set statut = 'accepte' where de = p_joueur and vers = auth.uid() and statut = 'attente';
  else delete from amities where de = p_joueur and vers = auth.uid() and statut = 'attente'; end if;
  return jsonb_build_object('ok', found);
end $$;
grant execute on function public.repondre_ami(uuid, boolean) to authenticated;

create or replace function public.retirer_ami(p_joueur uuid) returns void
language sql security definer set search_path = public as $$
  delete from amities where (de = auth.uid() and vers = p_joueur) or (de = p_joueur and vers = auth.uid())
$$;
grant execute on function public.retirer_ami(uuid) to authenticated;

-- ---------- Défis entre amis
create table if not exists public.defis (
  id bigint generated always as identity primary key,
  de uuid not null references auth.users(id) on delete cascade,
  vers uuid not null references auth.users(id) on delete cascade,
  code text not null,
  statut text not null default 'attente',
  cree timestamptz not null default now()
);
alter table public.defis enable row level security;

create or replace function public.defier_ami(p_joueur uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); c text;
begin
  if not exists (select 1 from amities where statut = 'accepte' and ((de = u and vers = p_joueur) or (de = p_joueur and vers = u))) then
    return jsonb_build_object('erreur', 'Vous ne pouvez défier que vos amis.');
  end if;
  update defis set statut = 'annule' where de = u and statut = 'attente';
  c := substr(md5(random()::text || clock_timestamp()::text), 1, 5);
  insert into defis (de, vers, code) values (u, p_joueur, c);
  return jsonb_build_object('code', c);
end $$;
grant execute on function public.defier_ami(uuid) to authenticated;

create or replace function public.mes_defis() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'de', coalesce(p.pseudo, 'Un joueur'), 'elo', p.elo, 'cree', d.cree) order by d.cree desc), '[]'::jsonb)
  from defis d join profils p on p.id = d.de
  where d.vers = auth.uid() and d.statut = 'attente' and d.cree > now() - interval '3 minutes'
$$;
grant execute on function public.mes_defis() to authenticated;

create or replace function public.repondre_defi(p_id bigint, p_accepter boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d defis;
begin
  update defis set statut = case when p_accepter then 'accepte' else 'refuse' end
  where id = p_id and vers = auth.uid() and statut = 'attente' and cree > now() - interval '3 minutes' returning * into d;
  if d.id is null then return jsonb_build_object('erreur', 'Ce défi n’est plus disponible.'); end if;
  return case when p_accepter then jsonb_build_object('code', d.code) else jsonb_build_object('ok', true) end;
end $$;
grant execute on function public.repondre_defi(bigint, boolean) to authenticated;

create or replace function public.annuler_defi() returns void
language sql security definer set search_path = public as $$ update defis set statut = 'annule' where de = auth.uid() and statut = 'attente' $$;
grant execute on function public.annuler_defi() to authenticated;

-- ---------- Boîte aux lettres
create table if not exists public.messages (
  id bigint generated always as identity primary key,
  joueur uuid not null references auth.users(id) on delete cascade,
  titre text not null,
  texte text not null default '',
  cadeau jsonb,
  lu boolean not null default false,
  recupere boolean not null default false,
  cree timestamptz not null default now()
);
create index if not exists messages_joueur on public.messages (joueur, cree desc);
alter table public.messages enable row level security;

create or replace function public.ma_boite() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) - 'joueur' order by m.cree desc), '[]'::jsonb) from (select * from messages where joueur = auth.uid() order by cree desc limit 50) m),
    'non_lus', (select count(*) from messages where joueur = auth.uid() and (not lu or (cadeau is not null and not recupere))))
$$;
grant execute on function public.ma_boite() to authenticated;

create or replace function public.lire_message(p_id bigint) returns void
language sql security definer set search_path = public as $$ update messages set lu = true where id = p_id and joueur = auth.uid() $$;
grant execute on function public.lire_message(bigint) to authenticated;

create or replace function public.supprimer_message(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from messages where id = p_id and joueur = auth.uid() and cadeau is not null and not recupere) then
    return jsonb_build_object('erreur', 'Récupérez d’abord le cadeau de ce message.');
  end if;
  delete from messages where id = p_id and joueur = auth.uid();
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.supprimer_message(bigint) to authenticated;

create or replace function public.recuperer_cadeau(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); m messages; x text;
begin
  update messages set recupere = true, lu = true where id = p_id and joueur = u and cadeau is not null and not recupere returning * into m;
  if m.id is null then return jsonb_build_object('erreur', 'Ce cadeau a déjà été récupéré.'); end if;
  update profils set pieces_or = pieces_or + coalesce((m.cadeau->>'or')::int, 0), encre = encre + coalesce((m.cadeau->>'encre')::int, 0) where id = u;
  for x in select jsonb_array_elements_text(coalesce(m.cadeau->'cartes', '[]'::jsonb)) loop perform ajouter_carte(u, x, 1); end loop;
  for x in select jsonb_array_elements_text(coalesce(m.cadeau->'paquets', '[]'::jsonb)) loop
    insert into paquets_offerts (joueur, type, nb) values (u, x, 1) on conflict (joueur, type) do update set nb = paquets_offerts.nb + 1;
  end loop;
  for x in select jsonb_array_elements_text(coalesce(m.cadeau->'variantes', '[]'::jsonb)) loop
    insert into variantes_joueur (joueur, variante) values (u, x) on conflict do nothing;
  end loop;
  return m.cadeau;
end $$;
grant execute on function public.recuperer_cadeau(bigint) to authenticated;

-- Administration : envoyer un message (destinataires : liste d’identifiants, ou null pour tous les joueurs)
drop function if exists public.admin_envoyer_message(uuid[], text, text, jsonb);
create or replace function public.admin_envoyer_message(p_dest jsonb, p_titre text, p_texte text, p_cadeau jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if coalesce(trim(p_titre), '') = '' then raise exception 'Le message doit avoir un titre.'; end if;
  insert into messages (joueur, titre, texte, cadeau)
  select p.id, left(trim(p_titre), 120), left(coalesce(p_texte, ''), 4000),
         case when p_cadeau is null or p_cadeau = '{}'::jsonb then null else p_cadeau end
  from profils p join auth.users u on u.id = p.id
  where (p_dest is null and u.email is not null)
     or (jsonb_typeof(p_dest) = 'array' and p.id::text in (select jsonb_array_elements_text(p_dest)));
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.admin_envoyer_message(jsonb, text, text, jsonb) to authenticated;

-- ---------- Notes de mise à jour
create table if not exists public.notes_maj (
  id bigint generated always as identity primary key,
  version text not null default '',
  titre text not null,
  texte text not null default '',
  publie boolean not null default false,
  cree timestamptz not null default now()
);
alter table public.notes_maj enable row level security;
drop policy if exists notes_maj_lecture on public.notes_maj;
create policy notes_maj_lecture on public.notes_maj for select using (publie or est_admin());

create or replace function public.admin_maj_note(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare i bigint;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if (p->>'id') is null then
    insert into notes_maj (version, titre, texte, publie) values (coalesce(p->>'version', ''), coalesce(nullif(p->>'titre', ''), 'Mise à jour'), coalesce(p->>'texte', ''), coalesce((p->>'publie')::boolean, false)) returning id into i;
  else
    update notes_maj set version = coalesce(p->>'version', ''), titre = coalesce(nullif(p->>'titre', ''), 'Mise à jour'), texte = coalesce(p->>'texte', ''),
      publie = coalesce((p->>'publie')::boolean, false) where id = (p->>'id')::bigint returning id into i;
  end if;
  return i;
end $$;
grant execute on function public.admin_maj_note(jsonb) to authenticated;

create or replace function public.admin_suppr_note(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  delete from notes_maj where id = p_id;
end $$;
grant execute on function public.admin_suppr_note(bigint) to authenticated;
