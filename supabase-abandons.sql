-- =====================================================================
-- MINUTEUR DE TOUR ET ABANDONS (parties en ligne avec au moins 2 joueurs humains)
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-2v2-ligne-suite.sql.
-- - présence : chaque joueur signale sa présence toutes les 15 secondes pendant la partie ;
-- - un abandon (bouton, déconnexion de plus de 60 secondes, 2 tours expirés) compte comme une défaite,
--   avec une perte de cote d’au moins 15 points ; le joueur qui part ne reçoit pas d’or ;
-- - 1 contre 1 : le joueur resté réclame la victoire si l’autre est absent depuis plus de 60 secondes ;
-- - 2 contre 2 : l’ordinateur remplace le joueur parti ; si toute une équipe humaine est partie,
--   l’autre équipe gagne par forfait ; un joueur dont l’allié est parti perd deux fois moins de cote ;
-- - une partie de moins de 75 secondes est annulée, sans effet sur la cote.
-- =====================================================================
create table if not exists public.presence_partie (
  partie text not null,
  joueur uuid not null references auth.users(id) on delete cascade,
  vu timestamptz not null default now(),
  primary key (partie, joueur)
);
alter table public.presence_partie enable row level security;
create table if not exists public.abandons_partie (
  partie text not null,
  joueur uuid not null references auth.users(id) on delete cascade,
  cree timestamptz not null default now(),
  primary key (partie, joueur)
);
alter table public.abandons_partie enable row level security;

-- Absent : aucun signe de présence depuis plus de 60 secondes
create or replace function public.absent_de(p_partie text, u uuid, depuis timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select vu from presence_partie where partie = p_partie and joueur = u), depuis) < now() - make_interval(secs => coalesce((reglage('delai_retour'))::int, 60))
$$;
revoke execute on function public.absent_de(text, uuid, timestamptz) from public, anon, authenticated;

create or replace function public.signe_presence(p_partie text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null or p_partie is null then return; end if;
  perform clore_parties_abandonnees();
  if not (exists (select 1 from tickets_partie where id::text = p_partie and (hote = u or invite = u))
          or exists (select 1 from salons_2v2 s where s.code = p_partie and siege_de(s, u) is not null)) then return; end if;
  insert into presence_partie (partie, joueur, vu) values (p_partie, u, now()) on conflict (partie, joueur) do update set vu = now();
end $$;
grant execute on function public.signe_presence(text) to authenticated;

-- ---------- Pénalité minimale d’un abandon (15 points par défaut)
create or replace function public.penalite_abandon_1v1(p_ticket text, u uuid) returns void
language plpgsql security definer set search_path = public as $$
declare h elo_historique; mini int := coalesce((reglage('penalite_abandon'))::int, 15);
begin
  select * into h from elo_historique where ticket = p_ticket and joueur = u and not annule;
  if not found or h.delta <= -mini then return; end if;
  update profils set elo = elo + (-mini - h.delta) where id = u;
  update elo_historique set delta = -mini, apres = avant - mini where id = h.id;
end $$;
revoke execute on function public.penalite_abandon_1v1(text, uuid) from public, anon, authenticated;

-- ---------- 1 contre 1 : déclaration d’abandon (bouton « Abandonner »)
create or replace function public.declarer_abandon(p_partie text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then return; end if;
  if exists (select 1 from tickets_partie where id::text = p_partie and (hote = u or invite = u))
     or exists (select 1 from salons_2v2 s where s.code = p_partie and siege_de(s, u) is not null) then
    insert into abandons_partie (partie, joueur) values (p_partie, u) on conflict do nothing;
  end if;
end $$;
grant execute on function public.declarer_abandon(text) to authenticated;

-- L’hôte a enregistré la partie (enregistrer_duel) : il signale lequel des deux a abandonné
create or replace function public.marquer_abandon_duel(p_ticket uuid, p_place int, p_raison text default 'abandon') returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; cible uuid; r parties_jouees;
begin
  select * into t from tickets_partie where id = p_ticket and hote = u and mode = 'enligne';
  if not found or p_place not in (0, 1) then return jsonb_build_object('erreur', 'Partie inconnue.'); end if;
  select * into r from parties_jouees where id_partie = p_ticket::text and place = p_place;
  if not found then return jsonb_build_object('erreur', 'Partie pas encore enregistrée.'); end if;
  if r.victoire then return jsonb_build_object('erreur', 'Le joueur désigné n’a pas perdu.'); end if;
  cible := case when p_place = 0 then t.hote else t.invite end;
  if cible <> u and not exists (select 1 from abandons_partie where partie = p_ticket::text and joueur = cible)
     and not absent_de(p_ticket::text, cible, t.cree) then
    if p_raison = 'inactif' then
      perform noter_alerte(u, 'abandon_par_inactivite', 'faible', jsonb_build_object('ticket', t.id, 'joueur', cible,
        'cause', 'L’hôte a déclaré son adversaire inactif (2 tours expirés) alors que celui-ci était encore connecté.'));
    else return jsonb_build_object('erreur', 'Votre adversaire est toujours présent.'); end if;
  end if;
  update parties_jouees set details = coalesce(details, '{}'::jsonb) || jsonb_build_object('abandon', true, 'raison', left(p_raison, 20))
   where id_partie = p_ticket::text and place = p_place;
  perform penalite_abandon_1v1(p_ticket::text, cible);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.marquer_abandon_duel(uuid, int, text) to authenticated;

-- L’hôte est parti : l’invité, resté, réclame la victoire
create or replace function public.reclamer_victoire_abandon(p_ticket uuid, d jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; duree int; min_s int := coalesce((reglage('duree_min_partie'))::int, 75); c jsonb := coalesce(d->'camp', '{}'::jsonb);
begin
  select * into t from tickets_partie where id = p_ticket and invite = u and mode = 'enligne' for update;
  if not found then return jsonb_build_object('erreur', 'Partie inconnue.'); end if;
  if t.enregistre or exists (select 1 from parties_jouees where id_partie = t.id::text) then return jsonb_build_object('erreur', 'Partie déjà enregistrée.'); end if;
  if absent_de(t.id::text, u, now()) then return jsonb_build_object('erreur', 'Vous n’êtes plus considéré comme présent dans cette partie.'); end if;
  if not exists (select 1 from abandons_partie where partie = t.id::text and joueur = t.hote) and not absent_de(t.id::text, t.hote, t.cree) then
    return jsonb_build_object('erreur', 'Votre adversaire est toujours présent.');
  end if;
  duree := extract(epoch from now() - t.cree)::int;
  if duree < min_s then
    update tickets_partie set enregistre = true where id = t.id;
    return jsonb_build_object('annulee', true, 'erreur', 'Partie trop courte : elle est annulée, sans effet sur la cote.');
  end if;
  insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s, heros, heros_adverse, details)
  values (t.id::text, 0, 'joueur', t.hote, u, 'enligne', false, false, borne(d->>'tours', 400), duree, left(d->>'heros_adverse', 30), left(c->>'heros', 30),
          jsonb_build_object('abandon', true, 'raison', 'deconnexion'));
  insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s, heros, heros_adverse,
                              degats, soins, creatures, sorts, achats, pouvoirs)
  values (t.id::text, 1, 'invite', u, u, 'enligne', true, false, borne(d->>'tours', 400), duree, left(c->>'heros', 30), left(d->>'heros_adverse', 30),
          borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300), borne(c->>'sorts', 400), borne(c->>'achats', 300), borne(c->>'pouvoirs', 60));
  update tickets_partie set enregistre = true where id = t.id;
  update elo_historique set confirme = true where ticket = t.id::text;
  perform penalite_abandon_1v1(t.id::text, t.hote);
  perform noter_alerte(u, 'victoire_par_abandon', 'faible', jsonb_build_object('ticket', t.id, 'adversaire', t.hote,
    'cause', 'Victoire réclamée après le départ de l’adversaire (absent depuis plus de 60 secondes). À surveiller si elle se répète souvent.'));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.reclamer_victoire_abandon(uuid, jsonb) to authenticated;

-- ---------- 2 contre 2
drop function if exists public.elo2v2_partie(uuid, tickets_partie, boolean);
create or replace function public.elo2v2_partie(u uuid, t tickets_partie, vict boolean, facteur numeric default 1, mini int default null) returns int
language plpgsql security definer set search_path = public as $$
declare s salons_2v2; k int := t.siege; eq int; ra numeric := 0; rb numeric := 0; humains_adv int := 0; v jsonb; i int := 0; e numeric; d int; p profils;
begin
  if t.salon is null then return null; end if;
  select * into s from salons_2v2 where code = t.salon; if not found then return null; end if;
  eq := k % 2;
  for v in select x from jsonb_array_elements(s.sieges) x loop
    if i % 2 = eq then ra := ra + coalesce((v->>'elo')::int, 1200);
    else rb := rb + coalesce((v->>'elo')::int, 1200);
         if jsonb_typeof(v) = 'object' then humains_adv := humains_adv + 1; end if; end if;
    i := i + 1;
  end loop;
  if humains_adv = 0 then return null; end if;   -- pas de cote contre des ordinateurs seuls
  select * into p from profils where id = u for update;
  e := 1 / (1 + power(10, ((rb / 2) - (ra / 2)) / 400.0));
  d := round(facteur * case when p.elo2v2_parties < 20 then 40 else 20 end * ((case when vict then 1 else 0 end) - e));
  if mini is not null and d > -mini then d := -mini; end if;
  update profils set elo2v2 = elo2v2 + d, elo2v2_parties = elo2v2_parties + 1, elo2v2_max = greatest(elo2v2_max, elo2v2 + d) where id = u;
  return d;
end $$;
revoke execute on function public.elo2v2_partie(uuid, tickets_partie, boolean, numeric, int) from public, anon, authenticated;

-- Un siège humain est « parti » : défaite d’abandon enregistrée, ou absent depuis plus de 60 secondes
create or replace function public.siege_parti_2v2(p_code text, p_siege int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case when jsonb_typeof(s.sieges->p_siege) <> 'object' then false
      else exists (select 1 from tickets_partie t join parties_jouees pj on pj.id_partie = t.id::text
                   where t.salon = s.code and t.siege = p_siege and coalesce((pj.details->>'abandon')::boolean, false))
        or absent_de(s.code, (s.sieges->p_siege->>'joueur')::uuid, coalesce(s.lance, s.cree)) end
    from salons_2v2 s where s.code = p_code), false)
$$;
revoke execute on function public.siege_parti_2v2(text, int) from public, anon, authenticated;

-- Toute l’équipe (0 : places 1 et 3 ; 1 : places 2 et 4) comptait au moins un humain, et tous sont partis
create or replace function public.equipe_partie_2v2(p_code text, p_eq int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select bool_or(jsonb_typeof(s.sieges->k) = 'object') and bool_and(jsonb_typeof(s.sieges->k) <> 'object' or siege_parti_2v2(s.code, k))
                   from salons_2v2 s, generate_series(p_eq, 3, 2) k where s.code = p_code), false)
$$;
revoke execute on function public.equipe_partie_2v2(text, int) from public, anon, authenticated;

-- Défaite par abandon d’un joueur de 2 contre 2 (appelée par le joueur lui-même, ou par l’hôte pour un absent ou un inactif)
create or replace function public.abandon_2v2(p_code text, p_siege int, p_raison text default 'abandon', d jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2; cible uuid; t tickets_partie; duree int; delta int; c jsonb := coalesce(d->'camp', '{}'::jsonb);
        min_s int := coalesce((reglage('duree_min_partie'))::int, 75); mini int := coalesce((reglage('penalite_abandon'))::int, 15);
begin
  select * into s from salons_2v2 where code = p_code;
  if not found or s.statut not in ('en_cours', 'termine') or p_siege not between 0 and 3 or jsonb_typeof(s.sieges->p_siege) <> 'object' then
    return jsonb_build_object('erreur', 'Place inconnue.');
  end if;
  cible := (s.sieges->p_siege->>'joueur')::uuid;
  if u <> cible and u <> s.hote then return jsonb_build_object('erreur', 'Seul l’hôte peut déclarer l’abandon d’un autre joueur.'); end if;
  select * into t from tickets_partie where salon = p_code and siege = p_siege and hote = cible;
  if not found then return jsonb_build_object('erreur', 'Ticket introuvable.'); end if;
  if exists (select 1 from parties_jouees where id_partie = t.id::text) then return jsonb_build_object('deja', true); end if;
  if u <> cible and not exists (select 1 from abandons_partie where partie = p_code and joueur = cible) and not absent_de(p_code, cible, coalesce(s.lance, s.cree)) then
    if p_raison = 'inactif' then
      perform noter_alerte(u, 'abandon_par_inactivite', 'faible', jsonb_build_object('salon', p_code, 'joueur', cible,
        'cause', 'L’hôte a déclaré un joueur inactif (2 tours expirés) alors que celui-ci était encore connecté.'));
    else return jsonb_build_object('attente', true); end if;
  end if;
  duree := extract(epoch from now() - t.cree)::int;
  if duree < min_s then
    insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s, details)
    values (t.id::text, 0, 'joueur', cible, u, '2v2', false, false, 1, duree, jsonb_build_object('abandon', true, 'annulee', true, 'raison', left(p_raison, 20)))
    on conflict do nothing;
    return jsonb_build_object('annulee', true);
  end if;
  insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s, heros,
                              degats, soins, creatures, sorts, achats, pouvoirs, details)
  values (t.id::text, 0, 'joueur', cible, u, '2v2', false, false, greatest(1, borne(d->>'tours', 400)), duree, left(c->>'heros', 30),
          borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300), borne(c->>'sorts', 400), borne(c->>'achats', 300), borne(c->>'pouvoirs', 60),
          jsonb_build_object('abandon', true, 'raison', left(p_raison, 20), 'en_ligne', true));
  delta := elo2v2_partie(cible, t, false, 1, mini);
  update parties_jouees set details = details || jsonb_build_object('elo', delta) where id_partie = t.id::text and joueur = cible;
  return jsonb_build_object('ok', true, 'elo', delta);
end $$;
grant execute on function public.abandon_2v2(text, int, text, jsonb) to authenticated;

-- Parties que plus personne ne termine : au bout de 10 minutes sans aucun joueur présent, chaque humain parti reçoit une défaite
create or replace function public.clore_parties_abandonnees() returns void
language plpgsql security definer set search_path = public as $$
declare s salons_2v2; k int; t tickets_partie; mini int := coalesce((reglage('penalite_abandon'))::int, 15);
begin
  for s in select * from salons_2v2 where statut = 'en_cours' and coalesce(lance, cree) < now() - interval '10 minutes'
             and not exists (select 1 from presence_partie p where p.partie = salons_2v2.code and p.vu > now() - interval '10 minutes') limit 20 loop
    for k in 0..3 loop
      if jsonb_typeof(s.sieges->k) = 'object' then
        select * into t from tickets_partie where salon = s.code and siege = k;
        if found and not exists (select 1 from parties_jouees where id_partie = t.id::text) then
          insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s, details)
          values (t.id::text, 0, 'joueur', t.hote, t.hote, '2v2', false, false, 1, extract(epoch from now() - t.cree)::int,
                  jsonb_build_object('abandon', true, 'raison', 'partie_abandonnee', 'en_ligne', true));
          perform elo2v2_partie(t.hote, t, false, 1, mini);
        end if;
      end if;
    end loop;
    update salons_2v2 set statut = 'termine' where code = s.code;
  end loop;
end $$;
revoke execute on function public.clore_parties_abandonnees() from public, anon, authenticated;

-- Enregistrement d’une partie de 2 contre 2 : forfait de l’équipe adverse, allié parti
create or replace function public.enregistrer_2v2(d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; c jsonb := d->'camp'; duree int; bonus int := 0; delta_elo int; forfait boolean := false; allie_parti boolean := false; vict boolean := coalesce((d->>'victoire')::boolean, false);
        min_s int := coalesce((reglage('duree_min_partie'))::int, 75); plafond int := coalesce((reglage('plafond_or_jour'))::int, 100); p profils; gain int;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  select * into t from tickets_partie where id = (d->>'ticket')::uuid and hote = u and mode = '2v2';
  if not found then perform noter_alerte(u, 'ticket_invente', 'forte', jsonb_build_object('ticket', d->>'ticket', 'cause', 'Ticket de 2 contre 2 inconnu ou appartenant à un autre joueur.')); return jsonb_build_object('erreur', 'Ticket de partie inconnu.'); end if;
  if exists (select 1 from parties_jouees where id_partie = t.id::text) then return jsonb_build_object('erreur', 'Partie déjà enregistrée.'); end if;
  duree := extract(epoch from now() - t.cree)::int;
  if duree < min_s then
    perform noter_alerte(u, 'partie_trop_courte', 'moyenne', jsonb_build_object('ticket', t.id, 'duree_s', duree, 'minimum_s', min_s, 'mode', '2v2',
      'cause', format('Partie de 2 contre 2 envoyée %s secondes après son ouverture, alors qu’une partie doit durer au moins %s secondes.', duree, min_s)));
    return jsonb_build_object('erreur', 'Partie trop courte pour être enregistrée.');
  end if;
  if coalesce((d->>'tours')::int, 0) not between 1 and 400 or not stats_plausibles(c) then
    perform noter_alerte(u, 'statistiques_impossibles', 'forte', jsonb_build_object('ticket', t.id, 'mode', '2v2', 'cause', 'Statistiques de 2 contre 2 hors limites.', 'camp_joueur', c));
    return jsonb_build_object('erreur', 'Statistiques invalides.');
  end if;
  -- Forfait : tous les joueurs humains de l’équipe adverse sont partis → victoire, quel que soit le résultat contre les ordinateurs
  if t.salon is not null then
    forfait := equipe_partie_2v2(t.salon, 1 - t.siege % 2);
    allie_parti := siege_parti_2v2(t.salon, (t.siege + 2) % 4);
    if forfait then vict := true; end if;
  end if;
  insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s, heros, heros_adverse,
                              degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees, palier, pv_fin, details)
  values (t.id::text, 0, 'joueur', u, u, '2v2', vict, false, (d->>'tours')::int, duree, left(c->>'heros', 30), null,
          borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300), borne(c->>'sorts', 400), borne(c->>'achats', 300), borne(c->>'pouvoirs', 60),
          case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end,
          case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end,
          least(greatest(coalesce((c->>'palier')::int, 0), 0), 2), least(greatest(coalesce((c->>'pv_fin')::int, 0), -200), 500),
          jsonb_build_object('allie', left(d->'details'->>'allie', 30),
                             'resurrections', least(greatest(coalesce((d->'details'->>'resurrections')::int, 0), 0), 20),
                             'chutes', least(greatest(coalesce((d->'details'->>'chutes')::int, 0), 0), 20), 'forfait', forfait));
  -- Or de fin de partie
  select * into p from profils where id = u for update;
  if p.jour is distinct from current_date then p.or_jour := 0; end if;
  gain := case when vict then (reglage('or_victoire'))::int else (reglage('or_defaite'))::int end;
  gain := greatest(0, least(gain, plafond - p.or_jour));
  update profils set pieces_or = pieces_or + gain, or_jour = p.or_jour + gain, jour = current_date where id = u;
  insert into recompenses_partie (ticket, joueur, gain) values (t.id, u, gain) on conflict do nothing;
  -- Victoire bonus du jour : la première victoire en 2 contre 2 de la journée
  if vict then
    insert into bonus_2v2 (joueur, jour) values (u, current_date) on conflict do nothing;
    if found then
      bonus := coalesce((reglage('bonus_victoire_2v2'))::int, 30);
      update profils set pieces_or = pieces_or + bonus where id = u;
    end if;
  end if;
  -- Défaite d’un joueur dont l’allié a abandonné : perte de cote divisée par deux
  delta_elo := elo2v2_partie(u, t, vict, case when not vict and allie_parti then 0.5 else 1 end);
  if t.salon is not null then update parties_jouees set details = details || jsonb_build_object('en_ligne', true, 'elo', delta_elo) where id_partie = t.id::text and joueur = u; end if;
  return jsonb_build_object('gain', gain, 'bonus', bonus, 'elo', delta_elo, 'forfait', forfait);
end $$;
grant execute on function public.enregistrer_2v2(jsonb) to authenticated;
