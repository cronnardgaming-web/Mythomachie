-- =====================================================================
-- 2 CONTRE 2 EN LIGNE (étape 1) : salons, recherche de partie, places, lancement avec bots, Elo du 2 contre 2
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-2v2-suite.sql et supabase-correctif-2v2.sql.
-- =====================================================================
create table if not exists public.salons_2v2 (
  code text primary key,
  hote uuid not null references auth.users(id) on delete cascade,
  public boolean not null default false,
  statut text not null default 'attente' check (statut in ('attente', 'en_cours', 'termine', 'annule')),
  sieges jsonb not null default '[null, null, null, null]'::jsonb,   -- [{joueur, pseudo} | null] × 4 ; null = bot
  vus jsonb not null default '{}'::jsonb,                            -- dernière présence de chaque joueur
  cree timestamptz not null default now(),
  lance timestamptz
);
alter table public.salons_2v2 enable row level security;
alter table public.tickets_partie add column if not exists salon text;
alter table public.tickets_partie add column if not exists siege int;
alter table public.profils add column if not exists elo2v2 int not null default 1200;
alter table public.profils add column if not exists elo2v2_parties int not null default 0;
alter table public.profils add column if not exists elo2v2_max int not null default 1200;

create or replace function public.siege_de(s salons_2v2, u uuid) returns int
language sql immutable as $$
  select (select k - 1 from jsonb_array_elements(s.sieges) with ordinality e(v, k) where v->>'joueur' = u::text limit 1)
$$;
create or replace function public.nb_humains(s salons_2v2) returns int
language sql immutable as $$ select count(*)::int from jsonb_array_elements(s.sieges) v where jsonb_typeof(v) = 'object' $$;

-- Retire d’un salon en attente les joueurs absents depuis plus de 20 secondes (le premier restant devient l’hôte)
create or replace function public.nettoyer_salon_2v2(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare s salons_2v2; k int; nv jsonb; changes boolean := false;
begin
  select * into s from salons_2v2 where code = p_code for update;
  if not found or s.statut <> 'attente' then return; end if;
  nv := s.sieges;
  for k in 0..3 loop
    if jsonb_typeof(nv->k) = 'object' and coalesce((s.vus->>(nv->k->>'joueur'))::timestamptz, s.cree) < now() - interval '20 seconds' then
      nv := jsonb_set(nv, array[k::text], 'null'::jsonb); changes := true;
    end if;
  end loop;
  if changes then
    update salons_2v2 set sieges = nv where code = p_code;
    s.sieges := nv;
    if nb_humains(s) = 0 then update salons_2v2 set statut = 'annule' where code = p_code;
    elsif siege_de(s, s.hote) is null then
      update salons_2v2 set hote = (select (v->>'joueur')::uuid from jsonb_array_elements(nv) v where jsonb_typeof(v) = 'object' limit 1) where code = p_code;
    end if;
  end if;
end $$;
revoke execute on function public.nettoyer_salon_2v2(text) from public, anon, authenticated;

create or replace function public.creer_salon_2v2(p_public boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); c text; ps text;
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  update salons_2v2 set sieges = (select jsonb_agg(case when v->>'joueur' = u::text then 'null'::jsonb else v end) from jsonb_array_elements(sieges) v)
   where statut = 'attente' and sieges::text like '%' || u::text || '%';   -- un joueur n’est que dans un salon à la fois
  select coalesce(pseudo, 'Joueur') into ps from profils where id = u;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 5));
    exit when not exists (select 1 from salons_2v2 where code = c);
  end loop;
  insert into salons_2v2 (code, hote, public, sieges, vus)
  values (c, u, coalesce(p_public, false), jsonb_build_array(jsonb_build_object('joueur', u, 'pseudo', ps), null, null, null), jsonb_build_object(u::text, now()));
  return c;
end $$;
grant execute on function public.creer_salon_2v2(boolean) to authenticated;

create or replace function public.rejoindre_salon_2v2(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2; k int; ps text;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  perform nettoyer_salon_2v2(upper(trim(p_code)));
  select * into s from salons_2v2 where code = upper(trim(p_code)) for update;
  if not found or s.statut in ('termine', 'annule') then return jsonb_build_object('erreur', 'Aucun salon ne correspond à ce code.'); end if;
  k := siege_de(s, u);
  if k is not null then return jsonb_build_object('code', s.code, 'siege', k); end if;
  if s.statut <> 'attente' then return jsonb_build_object('erreur', 'La partie de ce salon a déjà commencé.'); end if;
  select min(i) into k from generate_series(0, 3) i where jsonb_typeof(s.sieges->i) <> 'object';
  if k is null then return jsonb_build_object('erreur', 'Ce salon est complet.'); end if;
  select coalesce(pseudo, 'Joueur') into ps from profils where id = u;
  update salons_2v2 set sieges = jsonb_set(sieges, array[k::text], jsonb_build_object('joueur', u, 'pseudo', ps)),
                        vus = vus || jsonb_build_object(u::text, now()) where code = s.code;
  return jsonb_build_object('code', s.code, 'siege', k);
end $$;
grant execute on function public.rejoindre_salon_2v2(text) to authenticated;

-- Recherche de partie : rejoint le plus ancien salon public qui attend des joueurs, sinon en crée un
create or replace function public.chercher_salon_2v2() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); c text; r jsonb;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  for c in select code from salons_2v2 where public and statut = 'attente' and cree > now() - interval '3 minutes' and hote <> u
           order by cree loop
    perform nettoyer_salon_2v2(c);
    if exists (select 1 from salons_2v2 s where s.code = c and s.statut = 'attente' and nb_humains(s) between 1 and 3) then
      r := rejoindre_salon_2v2(c);
      if r ? 'siege' then return r; end if;
    end if;
  end loop;
  c := creer_salon_2v2(true);
  return jsonb_build_object('code', c, 'siege', 0, 'nouveau', true);
end $$;
grant execute on function public.chercher_salon_2v2() to authenticated;

create or replace function public.quitter_salon_2v2(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2; k int;
begin
  select * into s from salons_2v2 where code = p_code for update;
  if not found or s.statut <> 'attente' then return; end if;
  k := siege_de(s, u); if k is null then return; end if;
  s.sieges := jsonb_set(s.sieges, array[k::text], 'null'::jsonb);
  update salons_2v2 set sieges = s.sieges where code = p_code;
  if nb_humains(s) = 0 then update salons_2v2 set statut = 'annule' where code = p_code;
  elsif s.hote = u then update salons_2v2 set hote = (select (v->>'joueur')::uuid from jsonb_array_elements(s.sieges) v where jsonb_typeof(v) = 'object' limit 1) where code = p_code;
  end if;
end $$;
grant execute on function public.quitter_salon_2v2(text) to authenticated;

create or replace function public.changer_siege_2v2(p_code text, p_siege int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2; k int;
begin
  select * into s from salons_2v2 where code = p_code for update;
  if not found or s.statut <> 'attente' then return jsonb_build_object('erreur', 'Salon introuvable.'); end if;
  k := siege_de(s, u);
  if k is null or p_siege not between 0 and 3 then return jsonb_build_object('erreur', 'Place impossible.'); end if;
  if jsonb_typeof(s.sieges->p_siege) = 'object' then return jsonb_build_object('erreur', 'Cette place est prise.'); end if;
  update salons_2v2 set sieges = jsonb_set(jsonb_set(sieges, array[p_siege::text], sieges->k), array[k::text], 'null'::jsonb) where code = p_code;
  return jsonb_build_object('siege', p_siege);
end $$;
grant execute on function public.changer_siege_2v2(text, int) to authenticated;

-- État du salon (appelé toutes les 2 secondes : il sert aussi de signe de présence)
create or replace function public.etat_salon_2v2(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2; k int; t uuid;
begin
  update salons_2v2 set vus = vus || jsonb_build_object(u::text, now()) where code = p_code and sieges::text like '%' || u::text || '%';
  perform nettoyer_salon_2v2(p_code);
  select * into s from salons_2v2 where code = p_code;
  if not found then return jsonb_build_object('erreur', 'Salon introuvable.'); end if;
  k := siege_de(s, u);
  select id into t from tickets_partie where salon = s.code and hote = u order by cree desc limit 1;
  return jsonb_build_object('code', s.code, 'statut', s.statut, 'public', s.public, 'hote', s.hote = u, 'hote_id', s.hote, 'moi', k, 'ticket', t,
    'attente_s', extract(epoch from now() - s.cree)::int,
    'peut_lancer', s.hote = u and s.statut = 'attente' and (nb_humains(s) = 4 or now() - s.cree >= interval '15 seconds'),
    'sieges', (select jsonb_agg(case when jsonb_typeof(v) = 'object' then jsonb_build_object('joueur', v->>'joueur', 'pseudo', v->>'pseudo',
                 'elo2v2', (select elo2v2 from profils where id = (v->>'joueur')::uuid), 'moi', v->>'joueur' = u::text) else null end order by i)
               from jsonb_array_elements(s.sieges) with ordinality e(v, i)));
end $$;
grant execute on function public.etat_salon_2v2(text) to authenticated;

-- Lancement par l’hôte : les places vides deviennent des bots, chaque joueur humain reçoit son ticket
create or replace function public.lancer_salon_2v2(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s salons_2v2; v jsonb; i int := 0;
begin
  perform nettoyer_salon_2v2(p_code);
  select * into s from salons_2v2 where code = p_code for update;
  if not found or s.hote <> u then return jsonb_build_object('erreur', 'Seul l’hôte du salon peut lancer la partie.'); end if;
  if s.statut <> 'attente' then return jsonb_build_object('erreur', 'La partie a déjà été lancée.'); end if;
  if nb_humains(s) < 4 and now() - s.cree < interval '15 seconds' then return jsonb_build_object('erreur', 'Attendez encore quelques secondes que d’autres joueurs arrivent.'); end if;
  for v in select x from jsonb_array_elements(s.sieges) x loop
    if jsonb_typeof(v) = 'object' then
      insert into tickets_partie (hote, invite, mode, salon, siege) values ((v->>'joueur')::uuid, null, '2v2', s.code, i);
      -- Cote figée au lancement : chacun est évalué sur les mêmes valeurs, quel que soit l’ordre d’enregistrement
      s.sieges := jsonb_set(s.sieges, array[i::text], v || jsonb_build_object('elo', (select elo2v2 from profils where id = (v->>'joueur')::uuid)));
    end if;
    i := i + 1;
  end loop;
  update salons_2v2 set statut = 'en_cours', lance = now(), sieges = s.sieges where code = p_code;
  return jsonb_build_object('ok', true, 'sieges', s.sieges);
end $$;
grant execute on function public.lancer_salon_2v2(text) to authenticated;

create or replace function public.terminer_salon_2v2(p_code text) returns void
language sql security definer set search_path = public as $$
  update salons_2v2 set statut = 'termine' where code = p_code and hote = auth.uid() and statut = 'en_cours'
$$;
grant execute on function public.terminer_salon_2v2(text) to authenticated;

-- Elo du 2 contre 2 : appliqué à l’enregistrement d’une partie en ligne, si l’équipe adverse compte au moins un humain.
-- Chaque équipe vaut la moyenne de ses cotes (un bot compte pour 1200).
create or replace function public.elo2v2_partie(u uuid, t tickets_partie, vict boolean) returns int
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
  if humains_adv = 0 then return null; end if;   -- pas de cote contre des bots seuls
  select * into p from profils where id = u for update;
  e := 1 / (1 + power(10, ((rb / 2) - (ra / 2)) / 400.0));
  d := round(case when p.elo2v2_parties < 20 then 40 else 20 end * ((case when vict then 1 else 0 end) - e));
  update profils set elo2v2 = elo2v2 + d, elo2v2_parties = elo2v2_parties + 1, elo2v2_max = greatest(elo2v2_max, elo2v2 + d) where id = u;
  return d;
end $$;
revoke execute on function public.elo2v2_partie(uuid, tickets_partie, boolean) from public, anon, authenticated;

create or replace function public.classement_2v2(p_limite int default 100) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (select id, pseudo, titre, elo2v2, elo2v2_parties, elo2v2_max, rank() over (order by elo2v2 desc) rang from profils where elo2v2_parties > 0)
  select jsonb_build_object(
    'joueurs', (select coalesce(jsonb_agg(jsonb_build_object('rang', rang, 'pseudo', coalesce(pseudo, 'Joueur'), 'titre', titre, 'elo', elo2v2, 'parties', elo2v2_parties, 'moi', id = auth.uid()) order by rang), '[]'::jsonb)
                from (select * from c order by rang limit p_limite) x),
    'total', (select count(*) from c),
    'moi', (select jsonb_build_object('elo', p.elo2v2, 'parties', p.elo2v2_parties, 'max', p.elo2v2_max, 'rang', (select rang from c where c.id = p.id)) from profils p where p.id = auth.uid()))
$$;
grant execute on function public.classement_2v2(int) to authenticated;

-- Enregistrement d’une partie : ajoute l’Elo du 2 contre 2 pour les parties en ligne
create or replace function public.enregistrer_2v2(d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; c jsonb := d->'camp'; duree int; bonus int := 0; delta_elo int; vict boolean := coalesce((d->>'victoire')::boolean, false);
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
  insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s, heros, heros_adverse,
                              degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees, palier, pv_fin, details)
  values (t.id::text, 0, 'joueur', u, u, '2v2', vict, false, (d->>'tours')::int, duree, left(c->>'heros', 30), null,
          borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300), borne(c->>'sorts', 400), borne(c->>'achats', 300), borne(c->>'pouvoirs', 60),
          case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end,
          case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end,
          least(greatest(coalesce((c->>'palier')::int, 0), 0), 2), least(greatest(coalesce((c->>'pv_fin')::int, 0), -200), 500),
          jsonb_build_object('allie', left(d->'details'->>'allie', 30),
                             'resurrections', least(greatest(coalesce((d->'details'->>'resurrections')::int, 0), 0), 20),
                             'chutes', least(greatest(coalesce((d->'details'->>'chutes')::int, 0), 0), 20)));
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
  delta_elo := elo2v2_partie(u, t, vict);
  if t.salon is not null then update parties_jouees set details = details || jsonb_build_object('en_ligne', true, 'elo', delta_elo) where id_partie = t.id::text and joueur = u; end if;
  return jsonb_build_object('gain', gain, 'bonus', bonus, 'elo', delta_elo);
end $$;
grant execute on function public.enregistrer_2v2(jsonb) to authenticated;
