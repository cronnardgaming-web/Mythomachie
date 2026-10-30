-- =====================================================================
-- SAISONS : 12 travaux, 3 quêtes par travail, 4 paliers de récompenses
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-alertes-detaillees.sql.
-- =====================================================================

-- ---------- Nouvelles informations enregistrées pour chaque partie
alter table public.parties_jouees add column if not exists combos int not null default 0;
alter table public.parties_jouees add column if not exists equipements int not null default 0;
alter table public.parties_jouees add column if not exists bannis int not null default 0;
alter table public.parties_jouees add column if not exists palier int not null default 0;
alter table public.parties_jouees add column if not exists pv_fin int not null default 0;

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
                                     ('sorts', 'sorts joués', 400), ('achats', 'cartes achetées', 300), ('pouvoirs', 'pouvoirs utilisés', 60),
                                     ('combos', 'combos déclenchés', 300), ('equipements', 'équipements joués', 100), ('bannis', 'cartes bannies', 100)) x(cle, nom, maxi) loop
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
                                heros, heros_adverse, degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees,
                                combos, equipements, bannis, palier, pv_fin)
    values (t.id::text, i, typ, j, u, t.mode, v is not null and v = i, v is null, borne(d->>'tours', 400), duree,
            left(c->>'heros', 30), left(d->'cotes'->(1-i)->>'heros', 30),
            borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300),
            borne(c->>'sorts', 400), borne(c->>'achats', 300), borne(c->>'pouvoirs', 60),
            case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end,
            case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end,
            borne(c->>'combos', 300), borne(c->>'equipements', 100), borne(c->>'bannis', 100),
            least(greatest(coalesce((c->>'palier')::int, 0), 0), 2), least(greatest(coalesce((c->>'pv_fin')::int, 0), -200), 500))
    on conflict (id_partie, place) do nothing;
  end loop;
  update tickets_partie set enregistre = true where id = t.id;
  return null;
end $$;
grant execute on function public.enregistrer_duel(jsonb) to authenticated;

-- ---------- Cartes de saison : absentes des paquets et non fabricables jusqu’à la fin de la saison
alter table public.catalogue add column if not exists saison_fin date;

create or replace function public.admin_maj_catalogue(cartes jsonb) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  delete from catalogue where true;
  insert into catalogue (carte, rarete, achetable, faction, promo, saison_fin)
  select key, coalesce(value ->> 'rarete', 'commune'),
         not (coalesce((value ->> 'depart')::boolean, false) or coalesce((value ->> 'base')::boolean, false) or coalesce((value ->> 'jeton')::boolean, false)),
         nullif(value ->> 'faction', ''), coalesce((value ->> 'promo')::boolean, false),
         case when coalesce(value ->> 'saisonFin', '') ~ '^\d{4}-\d{2}-\d{2}$' then (value ->> 'saisonFin')::date end
  from jsonb_each(cartes);
  return (select count(*) from catalogue);
end $$;

drop function if exists public.tirer_carte(text, text);
create or replace function public.tirer_carte(r text, f text default null) returns text
language sql volatile set search_path = public as $$
  select carte from catalogue where rarete = r and achetable and not promo and (saison_fin is null or saison_fin <= current_date)
    and (f is null or faction = f) order by random() limit 1
$$;
revoke execute on function public.tirer_carte(text, text) from public, anon, authenticated;

create or replace function public.fabriquer(c text) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); v_nb int; v_max int := max_copies(c); r text; cout int;
begin
  select rarete into r from catalogue where carte = c and achetable and not promo and (saison_fin is null or saison_fin <= current_date);
  if r is null then raise exception 'Cette carte ne peut pas être fabriquée (carte de saison ou promotionnelle).'; end if;
  select coalesce(nb, 0) into v_nb from collection where joueur = u and carte = c;
  if coalesce(v_nb, 0) >= v_max then raise exception 'Vous avez déjà le nombre maximum d’exemplaires.'; end if;
  cout := (reglage('encre_fabrication') ->> r)::int;
  update profils set encre = encre - cout where id = u and encre >= cout;
  if not found then raise exception 'Encre insuffisante.'; end if;
  perform ajouter_carte(u, c, 1);
  return cout;
end $$;

-- ---------- Saisons
create table if not exists public.saisons (
  id text primary key,
  nom text not null,
  debut date not null,
  duree_jours int not null default 42,
  travaux jsonb not null default '[]'::jsonb,   -- [{nom, description, ouverture_jour, quetes:[{id, texte, type, but, param, recompense:{or|encre}}]}]
  paliers jsonb not null default '[]'::jsonb,   -- [{travaux, recompense:{or, encre, cartes[], paquets[], variantes[], titre}}]
  active boolean not null default true
);
alter table public.saisons enable row level security;
drop policy if exists saisons_lecture on public.saisons;
create policy saisons_lecture on public.saisons for select using (true);

create table if not exists public.saison_progres (
  joueur uuid not null references auth.users(id) on delete cascade,
  saison text not null references public.saisons(id) on delete cascade,
  quetes jsonb not null default '[]'::jsonb,
  paliers jsonb not null default '[]'::jsonb,
  primary key (joueur, saison)
);
alter table public.saison_progres enable row level security;
alter table public.profils add column if not exists titre text;

-- Saison en cours (la plus récente active, commencée et non terminée)
create or replace function public.saison_en_cours() returns saisons
language sql stable security definer set search_path = public as $$
  select * from saisons where active and debut <= current_date and current_date < debut + duree_jours order by debut desc limit 1
$$;

-- Progression d’une quête de saison depuis l’ouverture de son travail
create or replace function public.progres_saison(u uuid, ty text, param text, depuis timestamptz, jusque timestamptz) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int := case when param ~ '^-?\d+$' then param::int end; r int;
begin
  select coalesce(case ty
    when 'parties' then count(*)
    when 'victoires' then count(*) filter (where victoire)
    when 'parties_enligne' then count(*) filter (where mode = 'enligne')
    when 'victoires_enligne' then count(*) filter (where victoire and mode = 'enligne')
    when 'vic_pantheon' then count(*) filter (where victoire and heros = param)
    when 'vic_devotion' then count(*) filter (where victoire and palier >= coalesce(n, 1))
    when 'vic_pv' then count(*) filter (where victoire and pv_fin >= coalesce(n, 20))
    when 'vic_rapide' then count(*) filter (where victoire and tours <= coalesce(n, 20))
    when 'creatures' then sum(creatures) when 'sorts' then sum(sorts) when 'achats' then sum(achats)
    when 'degats' then sum(degats) when 'soins' then sum(soins) when 'pouvoirs' then sum(pouvoirs)
    when 'combos' then sum(combos) when 'equipements' then sum(equipements) when 'bannis' then sum(bannis)
  end, 0)::int into r
  from parties_jouees where joueur = u and mode in ('ia', 'enligne') and cree >= depuis and cree < jusque;
  return r;
end $$;
revoke execute on function public.progres_saison(uuid, text, text, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.ma_saison() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s saisons; p saison_progres; travaux jsonb := '[]'::jsonb; t jsonb; q jsonb; qs jsonb; k int := 0;
        ouv timestamptz; fin timestamptz; finis int := 0; tout_fait boolean; prog int;
begin
  select * into s from saison_en_cours();
  if s.id is null then return null; end if;
  fin := (s.debut + s.duree_jours)::timestamptz;
  select * into p from saison_progres where joueur = u and saison = s.id;
  for t in select x from jsonb_array_elements(s.travaux) x loop
    ouv := (s.debut + coalesce((t->>'ouverture_jour')::int, (k/2)*7 + (k%2)*3))::timestamptz;
    qs := '[]'::jsonb; tout_fait := true;
    for q in select x from jsonb_array_elements(coalesce(t->'quetes', '[]'::jsonb)) x loop
      prog := case when now() >= ouv then progres_saison(u, q->>'type', q->>'param', ouv, fin) else 0 end;
      qs := qs || (q || jsonb_build_object('progres', least(prog, (q->>'but')::int), 'faite', coalesce(p.quetes, '[]'::jsonb) ? (q->>'id')));
      if not (coalesce(p.quetes, '[]'::jsonb) ? (q->>'id')) then tout_fait := false; end if;
    end loop;
    if tout_fait and jsonb_array_length(qs) > 0 then finis := finis + 1; end if;
    travaux := travaux || (t - 'quetes' || jsonb_build_object('numero', k + 1, 'ouverture', ouv, 'ouvert', now() >= ouv, 'fini', tout_fait and jsonb_array_length(qs) > 0, 'quetes', qs));
    k := k + 1;
  end loop;
  return jsonb_build_object('id', s.id, 'nom', s.nom, 'debut', s.debut, 'fin', fin, 'travaux', travaux, 'finis', finis,
    'paliers', s.paliers, 'paliers_reclames', coalesce(p.paliers, '[]'::jsonb));
end $$;
grant execute on function public.ma_saison() to authenticated;

create or replace function public.reclamer_quete_saison(p_quete text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s jsonb := ma_saison(); t jsonb; q jsonb; rec jsonb;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  if s is null then return jsonb_build_object('erreur', 'Aucune saison en cours.'); end if;
  select x, tr into q, t from jsonb_array_elements(s->'travaux') tr, jsonb_array_elements(tr->'quetes') x where x->>'id' = p_quete;
  if q is null then perform noter_alerte(u, 'quete_saison_inconnue', 'forte', jsonb_build_object('quete', p_quete, 'cause', 'Quête de saison inexistante.')); return jsonb_build_object('erreur', 'Quête inconnue.'); end if;
  if (q->>'faite')::boolean then return jsonb_build_object('erreur', 'Quête déjà récompensée.'); end if;
  if not (t->>'ouvert')::boolean or (q->>'progres')::int < (q->>'but')::int then
    perform noter_alerte(u, 'quete_saison_non_terminee', 'forte', jsonb_build_object('quete', q->>'texte', 'progres', q->'progres', 'objectif', q->'but',
      'cause', format('Quête de saison « %s » réclamée avec une progression de %s sur %s.', q->>'texte', q->>'progres', q->>'but')));
    return jsonb_build_object('erreur', 'Cette quête n’est pas encore terminée.');
  end if;
  insert into saison_progres (joueur, saison, quetes) values (u, s->>'id', jsonb_build_array(p_quete))
  on conflict (joueur, saison) do update set quetes = saison_progres.quetes || to_jsonb(p_quete);
  rec := coalesce(q->'recompense', '{}'::jsonb);
  update profils set pieces_or = pieces_or + coalesce((rec->>'or')::int, 0), encre = encre + coalesce((rec->>'encre')::int, 0) where id = u;
  return rec;
end $$;
grant execute on function public.reclamer_quete_saison(text) to authenticated;

create or replace function public.reclamer_palier_saison(p_index int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s jsonb := ma_saison(); pal jsonb; rec jsonb; x text;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  if s is null then return jsonb_build_object('erreur', 'Aucune saison en cours.'); end if;
  pal := s->'paliers'->p_index;
  if pal is null then return jsonb_build_object('erreur', 'Palier inconnu.'); end if;
  if (s->'paliers_reclames') ? p_index::text then return jsonb_build_object('erreur', 'Récompense déjà obtenue.'); end if;
  if (s->>'finis')::int < (pal->>'travaux')::int then
    perform noter_alerte(u, 'palier_saison_non_atteint', 'forte', jsonb_build_object('palier', pal->'travaux', 'finis', s->'finis',
      'cause', format('Récompense du palier de %s travaux réclamée avec %s travaux finis.', pal->>'travaux', s->>'finis')));
    return jsonb_build_object('erreur', 'Ce palier n’est pas encore atteint.');
  end if;
  insert into saison_progres (joueur, saison, paliers) values (u, s->>'id', jsonb_build_array(p_index::text))
  on conflict (joueur, saison) do update set paliers = saison_progres.paliers || to_jsonb(p_index::text);
  rec := coalesce(pal->'recompense', '{}'::jsonb);
  update profils set pieces_or = pieces_or + coalesce((rec->>'or')::int, 0), encre = encre + coalesce((rec->>'encre')::int, 0),
                     titre = coalesce(nullif(rec->>'titre', ''), titre) where id = u;
  for x in select jsonb_array_elements_text(coalesce(rec->'cartes', '[]'::jsonb)) loop perform ajouter_carte(u, x, 1); end loop;
  for x in select jsonb_array_elements_text(coalesce(rec->'paquets', '[]'::jsonb)) loop
    insert into paquets_offerts (joueur, type, nb) values (u, x, 1) on conflict (joueur, type) do update set nb = paquets_offerts.nb + 1;
  end loop;
  for x in select jsonb_array_elements_text(coalesce(rec->'variantes', '[]'::jsonb)) loop
    insert into variantes_joueur (joueur, variante) values (u, x) on conflict do nothing;
  end loop;
  return rec;
end $$;
grant execute on function public.reclamer_palier_saison(int) to authenticated;

-- Administration : créer ou modifier une saison
create or replace function public.admin_maj_saison(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  insert into saisons (id, nom, debut, duree_jours, travaux, paliers, active)
  values (p->>'id', p->>'nom', (p->>'debut')::date, coalesce((p->>'duree_jours')::int, 42), coalesce(p->'travaux', '[]'::jsonb), coalesce(p->'paliers', '[]'::jsonb), coalesce((p->>'active')::boolean, true))
  on conflict (id) do update set nom = excluded.nom, debut = excluded.debut, duree_jours = excluded.duree_jours,
    travaux = excluded.travaux, paliers = excluded.paliers, active = excluded.active;
  return p->>'id';
end $$;
grant execute on function public.admin_maj_saison(jsonb) to authenticated;
