-- =====================================================================
-- CLASSEMENT ELO des parties en ligne, et file d’attente « Partie classée »
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après les autres scripts.
-- =====================================================================

alter table public.profils add column if not exists elo int not null default 1200;
alter table public.profils add column if not exists elo_parties int not null default 0;
alter table public.profils add column if not exists elo_max int not null default 1200;

create table if not exists public.elo_historique (
  id bigint generated always as identity primary key,
  ticket text not null,
  joueur uuid not null references auth.users(id) on delete cascade,
  adversaire uuid references auth.users(id) on delete set null,
  avant int not null, apres int not null, delta int not null,
  resultat numeric not null,
  confirme boolean not null default false,
  annule boolean not null default false,
  cree timestamptz not null default now()
);
create index if not exists elo_historique_joueur on public.elo_historique (joueur, cree desc);
alter table public.elo_historique enable row level security;
drop policy if exists elo_historique_lecture on public.elo_historique;
create policy elo_historique_lecture on public.elo_historique for select to authenticated using (joueur = auth.uid());

-- ---------- Calcul : à l’enregistrement du second camp d’une partie en ligne
create or replace function public.appliquer_elo() returns trigger
language plpgsql security definer set search_path = public as $$
declare r0 parties_jouees; pa profils; pb profils; sa numeric; ea numeric; ka int; kb int; da int; db int;
begin
  if new.place <> 1 or new.mode <> 'enligne' or new.joueur is null then return new; end if;
  select * into r0 from parties_jouees where id_partie = new.id_partie and place = 0;
  if r0.joueur is null or r0.joueur = new.joueur then return new; end if;
  if exists (select 1 from elo_historique where ticket = new.id_partie) then return new; end if;
  select * into pa from profils where id = r0.joueur for update;
  select * into pb from profils where id = new.joueur for update;
  sa := case when r0.egalite then 0.5 when r0.victoire then 1 else 0 end;
  ea := 1 / (1 + power(10, (pb.elo - pa.elo) / 400.0));
  ka := case when pa.elo_parties < 20 then 40 else 20 end;
  kb := case when pb.elo_parties < 20 then 40 else 20 end;
  da := round(ka * (sa - ea)); db := round(kb * ((1 - sa) - (1 - ea)));
  update profils set elo = elo + da, elo_parties = elo_parties + 1, elo_max = greatest(elo_max, elo + da) where id = pa.id;
  update profils set elo = elo + db, elo_parties = elo_parties + 1, elo_max = greatest(elo_max, elo + db) where id = pb.id;
  insert into elo_historique (ticket, joueur, adversaire, avant, apres, delta, resultat) values
    (new.id_partie, pa.id, pb.id, pa.elo, pa.elo + da, da, sa),
    (new.id_partie, pb.id, pa.id, pb.elo, pb.elo + db, db, 1 - sa);
  return new;
end $$;
drop trigger if exists parties_elo on public.parties_jouees;
create trigger parties_elo after insert on public.parties_jouees for each row execute function public.appliquer_elo();

-- ---------- Confirmation du résultat par l’invité (l’hôte a déclaré le résultat)
create or replace function public.confirmer_resultat(p_ticket uuid, p_victoire boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; r parties_jouees; h elo_historique;
begin
  select * into t from tickets_partie where id = p_ticket and invite = u and mode = 'enligne';
  if not found then return jsonb_build_object('erreur', 'Partie inconnue.'); end if;
  select * into r from parties_jouees where id_partie = p_ticket::text and joueur = u;
  if not found then return jsonb_build_object('attente', true); end if;
  if r.egalite or r.victoire = p_victoire then
    update elo_historique set confirme = true where ticket = p_ticket::text;
    select * into h from elo_historique where ticket = p_ticket::text and joueur = u;
    return jsonb_build_object('ok', true, 'delta', h.delta, 'elo', h.apres);
  end if;
  -- Désaccord : les points échangés sont annulés, et l’administrateur est prévenu
  if exists (select 1 from elo_historique where ticket = p_ticket::text and not annule) then
    update profils p set elo = p.elo - h2.delta, elo_parties = greatest(0, p.elo_parties - 1)
      from elo_historique h2 where h2.ticket = p_ticket::text and not h2.annule and p.id = h2.joueur;
    update elo_historique set annule = true where ticket = p_ticket::text;
  end if;
  perform noter_alerte(t.hote, 'resultat_conteste', 'forte', jsonb_build_object('ticket', t.id, 'invite', u,
    'cause', format('L’invité affirme avoir %s, alors que l’hôte a déclaré l’inverse. Les points de classement de cette partie ont été annulés.', case when p_victoire then 'gagné' else 'perdu' end)));
  perform noter_alerte(u, 'contestation_resultat', 'moyenne', jsonb_build_object('ticket', t.id, 'hote', t.hote,
    'cause', 'Ce joueur a contesté le résultat déclaré par son adversaire. À surveiller s’il conteste souvent ses défaites.'));
  return jsonb_build_object('conteste', true);
end $$;
grant execute on function public.confirmer_resultat(uuid, boolean) to authenticated;

-- ---------- Classement
create or replace function public.classement(p_limite int default 100) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (
    select p.id, p.pseudo, p.titre, p.elo, p.elo_parties, p.elo_max,
           rank() over (order by p.elo desc) rang
    from profils p where p.elo_parties > 0)
  select jsonb_build_object(
    'joueurs', (select coalesce(jsonb_agg(jsonb_build_object('rang', rang, 'pseudo', coalesce(pseudo, 'Joueur'), 'titre', titre, 'elo', elo,
        'parties', elo_parties, 'moi', id = auth.uid()) order by rang, elo_parties desc), '[]'::jsonb) from (select * from c order by rang limit p_limite) x),
    'total', (select count(*) from c),
    'moi', (select jsonb_build_object('elo', p.elo, 'parties', p.elo_parties, 'max', p.elo_max, 'rang', (select rang from c where c.id = p.id),
        'historique', (select coalesce(jsonb_agg(jsonb_build_object('delta', h.delta, 'apres', h.apres, 'resultat', h.resultat, 'cree', h.cree,
              'adversaire', (select pseudo from profils where id = h.adversaire), 'annule', h.annule) order by h.cree desc), '[]'::jsonb)
           from (select * from elo_historique where joueur = p.id order by cree desc limit 15) h))
      from profils p where p.id = auth.uid()))
$$;
grant execute on function public.classement(int) to authenticated;

-- ---------- File d’attente « Partie classée »
create table if not exists public.file_classee (
  joueur uuid primary key references auth.users(id) on delete cascade,
  elo int not null,
  depuis timestamptz not null default now(),
  vu timestamptz not null default now(),
  code text, role text, adversaire uuid
);
alter table public.file_classee enable row level security;

create or replace function public.chercher_adversaire() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); moi file_classee; a file_classee; c text;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  delete from file_classee where vu < now() - interval '30 seconds';
  select * into moi from file_classee where joueur = u for update;
  if not found then
    insert into file_classee (joueur, elo) select u, elo from profils where id = u returning * into moi;
  end if;
  update file_classee set vu = now() where joueur = u;
  if moi.code is not null then
    delete from file_classee where joueur = u;
    return jsonb_build_object('code', moi.code, 'role', moi.role, 'adversaire', (select pseudo from profils where id = moi.adversaire));
  end if;
  -- Écart de cote accepté : 100 points, puis +50 toutes les 10 secondes d’attente (jusqu’à 1 000)
  select * into a from file_classee f where f.joueur <> u and f.code is null
    and abs(f.elo - moi.elo) <= least(1000, 100 + 5 * extract(epoch from now() - least(f.depuis, moi.depuis))::int)
    order by abs(f.elo - moi.elo), f.depuis limit 1 for update skip locked;
  if a.joueur is null then
    return jsonb_build_object('attente', true, 'depuis_s', extract(epoch from now() - moi.depuis)::int, 'en_file', (select count(*) from file_classee));
  end if;
  c := substr(md5(random()::text || clock_timestamp()::text), 1, 5);
  update file_classee set code = c, role = 'hote', adversaire = u where joueur = a.joueur;
  delete from file_classee where joueur = u;
  return jsonb_build_object('code', c, 'role', 'invite', 'adversaire', (select pseudo from profils where id = a.joueur));
end $$;
grant execute on function public.chercher_adversaire() to authenticated;

create or replace function public.quitter_file() returns void
language sql security definer set search_path = public as $$ delete from file_classee where joueur = auth.uid() $$;
grant execute on function public.quitter_file() to authenticated;
