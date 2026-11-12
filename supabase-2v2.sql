-- =====================================================================
-- 2 CONTRE 2 : parties enregistrées (avec or), quêtes du jour propres au mode, statistiques
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après les autres scripts.
-- Les parties en 2 contre 2 comptent dans les statistiques générales et les trophées du joueur,
-- mais pas dans les quêtes du jour classiques, la saison ou le classement.
-- =====================================================================
alter table public.parties_jouees add column if not exists details jsonb not null default '{}'::jsonb;

create or replace function public.commencer_2v2() returns uuid
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t uuid; max_h int := coalesce((reglage('parties_par_heure'))::int, 60);
begin
  if u is null then return null; end if;
  if (select count(*) from tickets_partie where hote = u and cree > now() - interval '1 hour') >= max_h then
    perform noter_alerte(u, 'trop_de_parties', 'moyenne', jsonb_build_object('limite', max_h, 'cause', 'Trop de parties commencées en une heure.')); return null;
  end if;
  insert into tickets_partie (hote, invite, mode) values (u, null, '2v2') returning id into t;
  return t;
end $$;
grant execute on function public.commencer_2v2() to authenticated;

-- Enregistre une partie de 2 contre 2 et verse l’or (mêmes gains et même plafond journalier qu’une partie classique)
create or replace function public.enregistrer_2v2(d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; c jsonb := d->'camp'; duree int; vict boolean := coalesce((d->>'victoire')::boolean, false);
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
  return jsonb_build_object('gain', gain);
end $$;
grant execute on function public.enregistrer_2v2(jsonb) to authenticated;

-- ---------- Quêtes du jour du 2 contre 2 (3 par jour, tirées dans cette liste)
create or replace function public.catalogue_quetes_2v2() returns jsonb
language sql immutable as $$ select '[
  {"id":"q2_parties3","texte":"Jouer 3 parties en 2 contre 2","cle":"parties","but":3,"or":20},
  {"id":"q2_victoires2","texte":"Gagner 2 parties en 2 contre 2","cle":"victoires","but":2,"or":25},
  {"id":"q2_degats80","texte":"Infliger 80 dégâts en 2 contre 2","cle":"degats","but":80,"or":20},
  {"id":"q2_soins30","texte":"Soigner 30 points de vie en 2 contre 2","cle":"soins","but":30,"or":20},
  {"id":"q2_creatures12","texte":"Poser 12 créatures en 2 contre 2","cle":"creatures","but":12,"or":20},
  {"id":"q2_pouvoir2","texte":"Utiliser 2 fois le pouvoir de votre divinité en 2 contre 2","cle":"pouvoirs","but":2,"or":20},
  {"id":"q2_resurrection","texte":"Voir un membre de votre équipe revenir à la vie","cle":"resurrections","but":1,"or":20},
  {"id":"q2_sans_chute","texte":"Gagner une partie sans qu’aucun héros de votre équipe ne tombe","cle":"vic_sans_chute","but":1,"or":30}
]'::jsonb $$;

create table if not exists public.quetes_2v2 (
  joueur uuid not null references auth.users(id) on delete cascade,
  jour date not null default current_date,
  ids jsonb not null,
  faites jsonb not null default '[]'::jsonb,
  primary key (joueur, jour)
);
alter table public.quetes_2v2 enable row level security;

create or replace function public.progres_2v2(u uuid, cle text) returns int
language plpgsql stable security definer set search_path = public as $$
declare r int;
begin
  select coalesce(case cle
    when 'parties' then count(*) when 'victoires' then count(*) filter (where victoire)
    when 'degats' then sum(degats) when 'soins' then sum(soins) when 'creatures' then sum(creatures) when 'pouvoirs' then sum(pouvoirs)
    when 'resurrections' then sum(coalesce((details->>'resurrections')::int, 0))
    when 'vic_sans_chute' then count(*) filter (where victoire and coalesce((details->>'chutes')::int, 0) = 0)
  end, 0)::int into r
  from parties_jouees where joueur = u and mode = '2v2' and cree::date = current_date;
  return r;
end $$;
revoke execute on function public.progres_2v2(uuid, text) from public, anon, authenticated;

create or replace function public.mes_quetes_2v2() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); q quetes_2v2; cat jsonb := catalogue_quetes_2v2();
begin
  if u is null then return null; end if;
  select * into q from quetes_2v2 where joueur = u and jour = current_date;
  if not found then
    insert into quetes_2v2 (joueur, ids) select u, jsonb_agg(x->'id') from (select x from jsonb_array_elements(cat) x order by random() limit 3) s returning * into q;
  end if;
  return (select jsonb_build_object('quetes', jsonb_agg(c || jsonb_build_object('progres', least(progres_2v2(u, c->>'cle'), (c->>'but')::int), 'faite', q.faites ? (c->>'id')) order by ord))
          from jsonb_array_elements(q.ids) with ordinality i(id, ord) join jsonb_array_elements(cat) c on c->'id' = i.id);
end $$;
grant execute on function public.mes_quetes_2v2() to authenticated;

create or replace function public.reclamer_quete_2v2(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); q quetes_2v2; c jsonb;
begin
  select * into q from quetes_2v2 where joueur = u and jour = current_date for update;
  if not found or not (q.ids ? p_id) then return jsonb_build_object('erreur', 'Quête inconnue.'); end if;
  if q.faites ? p_id then return jsonb_build_object('erreur', 'Quête déjà récompensée.'); end if;
  select x into c from jsonb_array_elements(catalogue_quetes_2v2()) x where x->>'id' = p_id;
  if progres_2v2(u, c->>'cle') < (c->>'but')::int then
    perform noter_alerte(u, 'quete_non_terminee', 'forte', jsonb_build_object('quete', c->>'texte', 'cause', format('Quête de 2 contre 2 « %s » réclamée avant d’être terminée.', c->>'texte')));
    return jsonb_build_object('erreur', 'Cette quête n’est pas encore terminée.');
  end if;
  update quetes_2v2 set faites = faites || to_jsonb(p_id) where joueur = u and jour = current_date;
  update profils set pieces_or = pieces_or + (c->>'or')::int where id = u;
  return jsonb_build_object('or', (c->>'or')::int);
end $$;
grant execute on function public.reclamer_quete_2v2(text) to authenticated;

-- ---------- Statistiques du 2 contre 2
create or replace function public.mes_stats_2v2() returns jsonb
language sql stable security definer set search_path = public as $$
  with p as (select * from parties_jouees where joueur = auth.uid() and mode = '2v2')
  select jsonb_build_object(
    'parties', (select count(*) from p), 'victoires', (select count(*) from p where victoire),
    'degats', (select coalesce(sum(degats), 0) from p), 'soins', (select coalesce(sum(soins), 0) from p),
    'creatures', (select coalesce(sum(creatures), 0) from p), 'pouvoirs', (select coalesce(sum(pouvoirs), 0) from p),
    'resurrections', (select coalesce(sum((details->>'resurrections')::int), 0) from p),
    'chutes', (select coalesce(sum((details->>'chutes')::int), 0) from p),
    'sans_chute', (select count(*) from p where victoire and coalesce((details->>'chutes')::int, 0) = 0),
    'par_heros', (select coalesce(jsonb_object_agg(heros, jsonb_build_object('parties', n, 'victoires', v)), '{}'::jsonb)
                  from (select heros, count(*) n, count(*) filter (where victoire) v from p where heros is not null group by heros) x))
$$;
grant execute on function public.mes_stats_2v2() to authenticated;
