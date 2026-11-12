-- =====================================================================
-- 2 CONTRE 2 (suite) : victoire bonus du jour, trophées « Frères d’armes » et « Indestructibles »
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-2v2.sql.
-- Le montant du bonus se règle avec la clé « bonus_victoire_2v2 » des réglages économiques (30 or par défaut).
-- =====================================================================
create table if not exists public.bonus_2v2 (
  joueur uuid not null references auth.users(id) on delete cascade,
  jour date not null default current_date,
  primary key (joueur, jour)
);
alter table public.bonus_2v2 enable row level security;

create or replace function public.etat_bonus_2v2() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('disponible', not exists (select 1 from bonus_2v2 where joueur = auth.uid() and jour = current_date),
                            'montant', coalesce((reglage('bonus_victoire_2v2'))::int, 30))
$$;
grant execute on function public.etat_bonus_2v2() to authenticated;

create or replace function public.enregistrer_2v2(d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; c jsonb := d->'camp'; duree int; bonus int := 0; vict boolean := coalesce((d->>'victoire')::boolean, false);
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
  return jsonb_build_object('gain', gain, 'bonus', bonus);
end $$;
grant execute on function public.enregistrer_2v2(jsonb) to authenticated;

-- Trophées : deux nouveaux trophées propres au 2 contre 2
create or replace function public.catalogue_trophees() returns jsonb
language sql immutable as $$
  select '[
    {"id":"parties","paliers":[10,50,200,500]},
    {"id":"victoires","paliers":[5,25,100,300]},
    {"id":"serie","paliers":[3,5,10,15]},
    {"id":"degats","paliers":[500,3000,15000,40000]},
    {"id":"soins","paliers":[200,1500,6000,15000]},
    {"id":"creatures","paliers":[50,300,1500,4000]},
    {"id":"achats","paliers":[50,300,1500,4000]},
    {"id":"pouvoirs","paliers":[5,25,100,250]},
    {"id":"pantheons","paliers":[1,5,20,50]},
    {"id":"collection","paliers":[40,80,120,-1]},
    {"id":"champion_egy","paliers":[5,25,75,200],"pantheon":"egy"},
    {"id":"champion_hin","paliers":[5,25,75,200],"pantheon":"hin"},
    {"id":"champion_nor","paliers":[5,25,75,200],"pantheon":"nor"},
    {"id":"champion_gre","paliers":[5,25,75,200],"pantheon":"gre"},
    {"id":"freres_armes","paliers":[3,15,50,150]},
    {"id":"indestructibles","paliers":[1,5,20,60]}
  ]'::jsonb
$$;

create or replace function public.valeur_trophee(u uuid, t text, s jsonb, palier int, out valeur int, out seuil int)
language plpgsql stable security definer set search_path = public as $$
declare th jsonb := (select x from jsonb_array_elements(catalogue_trophees()) x where x->>'id' = t);
begin
  seuil := (th->'paliers'->>(palier - 1))::int;
  valeur := case t
    when 'parties' then (s->>'parties')::int when 'victoires' then (s->>'victoires')::int when 'serie' then (s->>'serie_max')::int
    when 'degats' then (s->>'degats')::int when 'soins' then (s->>'soins')::int when 'creatures' then (s->>'creatures')::int
    when 'achats' then (s->>'achats')::int when 'pouvoirs' then (s->>'pouvoirs')::int
    when 'pantheons' then (select coalesce(min(coalesce((s->'par_heros'->f->>'victoires')::int, 0)), 0) from unnest(array['egy','hin','nor','gre']) f)
    when 'collection' then (select count(*) from collection c join catalogue k on k.carte = c.carte where c.joueur = u and c.nb > 0 and k.achetable and not k.promo)
    when 'freres_armes' then (select count(*) from parties_jouees where joueur = u and mode = '2v2' and victoire)::int
    when 'indestructibles' then (select count(*) from parties_jouees where joueur = u and mode = '2v2' and victoire and coalesce((details->>'chutes')::int, 0) = 0)::int
    else coalesce((s->'par_heros'->(th->>'pantheon')->>'victoires')::int, 0) end;
  if t = 'collection' and seuil = -1 then
    seuil := (select count(*) from catalogue where achetable and not promo);
    valeur := (select count(*) from collection c join catalogue k on k.carte = c.carte where c.joueur = u and k.achetable and not k.promo and c.nb >= max_copies(c.carte));
  end if;
end $$;
