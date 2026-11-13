-- =====================================================================
-- 2 CONTRE 2 EN LIGNE (étape 3) : invitations d’amis dans un salon, reprise du rôle d’hôte
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-2v2-ligne.sql.
-- =====================================================================
create table if not exists public.invitations_2v2 (
  id bigint generated always as identity primary key,
  de uuid not null references auth.users(id) on delete cascade,
  vers uuid not null references auth.users(id) on delete cascade,
  code text not null,
  cree timestamptz not null default now(),
  traitee boolean not null default false
);
alter table public.invitations_2v2 enable row level security;

-- Inviter un ami dans le salon où l’on se trouve (seulement un ami accepté)
create or replace function public.inviter_salon_2v2(p_ami uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2;
begin
  select * into s from salons_2v2 where code = p_code;
  if not found or s.statut <> 'attente' or siege_de(s, u) is null then return jsonb_build_object('erreur', 'Vous n’êtes pas dans ce salon.'); end if;
  if not exists (select 1 from amities where statut = 'accepte' and ((de = u and vers = p_ami) or (de = p_ami and vers = u))) then
    return jsonb_build_object('erreur', 'Vous ne pouvez inviter que vos amis.');
  end if;
  if siege_de(s, p_ami) is not null then return jsonb_build_object('erreur', 'Cet ami est déjà dans le salon.'); end if;
  if exists (select 1 from invitations_2v2 where de = u and vers = p_ami and code = p_code and not traitee and cree > now() - interval '3 minutes') then
    return jsonb_build_object('erreur', 'Invitation déjà envoyée.');
  end if;
  insert into invitations_2v2 (de, vers, code) values (u, p_ami, p_code);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.inviter_salon_2v2(uuid, text) to authenticated;

-- Invitations reçues récentes, pour des salons qui attendent encore des joueurs
create or replace function public.mes_invitations_2v2() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'de', coalesce(p.pseudo, 'Un ami'), 'code', i.code) order by i.cree desc), '[]'::jsonb)
  from invitations_2v2 i join profils p on p.id = i.de join salons_2v2 s on s.code = i.code
  where i.vers = auth.uid() and not i.traitee and i.cree > now() - interval '3 minutes' and s.statut = 'attente' and nb_humains(s) < 4
$$;
grant execute on function public.mes_invitations_2v2() to authenticated;

create or replace function public.repondre_invitation_2v2(p_id bigint, p_accepte boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i invitations_2v2;
begin
  update invitations_2v2 set traitee = true where id = p_id and vers = auth.uid() and not traitee returning * into i;
  if not found then return jsonb_build_object('erreur', 'Invitation expirée.'); end if;
  if not p_accepte then return jsonb_build_object('ok', true); end if;
  return rejoindre_salon_2v2(i.code);
end $$;
grant execute on function public.repondre_invitation_2v2(bigint, boolean) to authenticated;

-- Reprise du rôle d’hôte par un joueur de la partie quand l’hôte est parti
create or replace function public.reprendre_salon_2v2(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2;
begin
  select * into s from salons_2v2 where code = p_code for update;
  if not found or s.statut <> 'en_cours' or siege_de(s, u) is null then return jsonb_build_object('erreur', 'Reprise impossible.'); end if;
  update salons_2v2 set hote = u where code = p_code;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.reprendre_salon_2v2(text) to authenticated;
