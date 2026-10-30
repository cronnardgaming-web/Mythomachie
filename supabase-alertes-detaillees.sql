-- =====================================================================
-- ALERTES DÉTAILLÉES : numéro de ticket et cause exacte du blocage
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après tous les autres scripts.
-- Le comportement ne change pas (les mêmes parties sont acceptées ou refusées) :
-- seules les informations notées dans les alertes sont plus précises.
-- =====================================================================

-- Regroupement d’alertes identiques le même jour : on garde la gravité la plus élevée
create or replace function public.noter_alerte(p_joueur uuid, p_motif text, p_gravite text, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into alertes (joueur, motif, gravite, details) values (p_joueur, p_motif, p_gravite, coalesce(p_details, '{}'::jsonb))
  on conflict (joueur, motif, jour) do update
    set compteur = alertes.compteur + 1, derniere = now(), details = excluded.details, traite = false,
        gravite = case when 'forte' in (alertes.gravite, excluded.gravite) then 'forte'
                       when 'moyenne' in (alertes.gravite, excluded.gravite) then 'moyenne' else 'faible' end
$$;
revoke execute on function public.noter_alerte(uuid, text, text, jsonb) from public, anon, authenticated;

-- Cartes d’une partie absentes du catalogue du serveur
create or replace function public.cartes_hors_catalogue(d jsonb) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct e.key order by e.key), '{}')
  from jsonb_array_elements(case when jsonb_typeof(d->'cotes') = 'array' then d->'cotes' else '[]'::jsonb end) c,
       lateral (select key from jsonb_each(case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end)
                union select key from jsonb_each(case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end)) e
  where not exists (select 1 from catalogue k where k.carte = e.key)
$$;

-- Toutes les raisons de refuser les statistiques d’une partie, en clair
create or replace function public.raisons_stats(d jsonb) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r text[] := '{}'; i int; c jsonb; camp text; lim record; v numeric; k text; e record;
begin
  if coalesce((d->>'tours')::numeric, 0) not between 1 and 400 then
    r := r || format('Nombre de tours déclaré : %s (attendu entre 1 et 400).', coalesce(d->>'tours', 'aucun'));
  end if;
  for i in 0..1 loop
    c := d->'cotes'->i; camp := case when i = 0 then 'Camp du joueur' else 'Camp adverse' end;
    if jsonb_typeof(c) is distinct from 'object' then r := r || format('%s : statistiques absentes ou mal formées.', camp); continue; end if;
    for lim in select * from (values ('degats', 'dégâts infligés', 2000), ('soins', 'points de vie soignés', 2000), ('creatures', 'créatures jouées', 300),
                                     ('sorts', 'sorts joués', 400), ('achats', 'cartes achetées', 300), ('pouvoirs', 'pouvoirs utilisés', 60)) x(cle, nom, maxi) loop
      v := coalesce((c->>lim.cle)::numeric, 0);
      if v < 0 or v > lim.maxi then r := r || format('%s : %s %s (maximum autorisé : %s).', camp, v, lim.nom, lim.maxi); end if;
    end loop;
    foreach k in array array['jouees', 'achetees'] loop
      for e in select * from jsonb_each_text(case when jsonb_typeof(c->k) = 'object' then c->k else '{}'::jsonb end) loop
        if not exists (select 1 from catalogue where carte = e.key) then
          r := r || format('%s : la carte « %s » est absente du catalogue du serveur (catalogue non envoyé depuis son ajout ?).', camp, e.key);
        elsif e.value !~ '^\d{1,3}$' then
          r := r || format('%s : nombre d’exemplaires invalide pour « %s » (%s).', camp, e.key, e.value);
        end if;
      end loop;
    end loop;
  end loop;
  return r;
end $$;
revoke execute on function public.cartes_hors_catalogue(jsonb) from public, anon, authenticated;
revoke execute on function public.raisons_stats(jsonb) from public, anon, authenticated;

create or replace function public.enregistrer_duel(d jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid(); t tickets_partie; c jsonb; i int; typ text; j uuid; duree int; raisons text[]; inconnues text[];
  v int := case when d->>'vainqueur' in ('0', '1') then (d->>'vainqueur')::int else null end;
  min_s int := coalesce((reglage('duree_min_partie'))::int, 120);
begin
  if u is null then return 'Connexion requise.'; end if;
  if coalesce(d->>'id_partie', '') !~ '^[0-9a-f-]{36}$' then
    perform noter_alerte(u, 'partie_sans_ticket', 'forte', jsonb_build_object('identifiant_envoye', left(d->>'id_partie', 60),
      'cause', 'Aucun ticket valide n’a été fourni : cette partie n’a jamais été ouverte par le serveur.')); return 'Ticket de partie inconnu.';
  end if;
  select * into t from tickets_partie where id = (d->>'id_partie')::uuid and hote = u for update;
  if not found then perform noter_alerte(u, 'ticket_invente', 'forte', jsonb_build_object('ticket', d->>'id_partie',
      'cause', 'Ce ticket n’existe pas ou appartient à un autre joueur.')); return 'Ticket de partie inconnu.'; end if;
  if t.enregistre then return null; end if;
  if t.mode <> coalesce(d->>'mode', '') then
    perform noter_alerte(u, 'mode_falsifie', 'forte', jsonb_build_object('ticket', t.id, 'mode_du_ticket', t.mode, 'mode_envoye', d->>'mode',
      'cause', format('Mode envoyé « %s », alors que la partie a été ouverte en mode « %s ».', d->>'mode', t.mode))); return 'Le mode ne correspond pas au ticket.';
  end if;
  duree := extract(epoch from now() - t.cree)::int;
  if duree < min_s then
    perform noter_alerte(u, 'partie_trop_courte', 'moyenne', jsonb_build_object('ticket', t.id, 'duree_s', duree, 'minimum_s', min_s, 'mode', t.mode, 'tours_declares', d->>'tours',
      'cause', format('La partie a été envoyée %s secondes après son ouverture, alors qu’une partie doit durer au moins %s secondes.', duree, min_s)));
    return 'Partie trop courte pour être enregistrée.';
  end if;
  if duree > 6*3600 then return 'Ticket de partie expiré.'; end if;
  raisons := raisons_stats(d);
  if array_length(raisons, 1) > 0 then
    inconnues := cartes_hors_catalogue(d);
    perform noter_alerte(u, 'statistiques_impossibles', case when cardinality(inconnues) = cardinality(raisons) then 'moyenne' else 'forte' end,
      jsonb_build_object('ticket', t.id, 'mode', t.mode, 'tours', d->>'tours', 'cause', array_to_string(raisons, ' '), 'cartes_inconnues', to_jsonb(inconnues),
                         'camp_joueur', d->'cotes'->0, 'camp_adverse', d->'cotes'->1));
    return 'Statistiques invalides.';
  end if;
  for i in 0..1 loop
    c := d->'cotes'->i;
    if t.mode = 'ia' then typ := case when i = 0 then 'joueur' else 'ordinateur' end; j := case when i = 0 then u end;
    elsif t.mode = 'duo' then typ := 'local'; j := null;
    else typ := case when i = 0 then 'joueur' else 'invite' end; j := case when i = 0 then u else t.invite end;
    end if;
    insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s,
                                heros, heros_adverse, degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees)
    values (t.id::text, i, typ, j, u, t.mode, v is not null and v = i, v is null, borne(d->>'tours', 400), duree,
            left(c->>'heros', 30), left(d->'cotes'->(1-i)->>'heros', 30),
            borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300),
            borne(c->>'sorts', 400), borne(c->>'achats', 300), borne(c->>'pouvoirs', 60),
            case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end,
            case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end)
    on conflict (id_partie, place) do nothing;
  end loop;
  update tickets_partie set enregistre = true where id = t.id;
  return null;
end $$;
grant execute on function public.enregistrer_duel(jsonb) to authenticated;
