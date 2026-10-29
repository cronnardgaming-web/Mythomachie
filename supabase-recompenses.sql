-- =====================================================================
-- QUÊTES DU JOUR (3 par joueur) ET TROPHÉES À 4 RANGS AVEC RÉCOMPENSES
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-variantes.sql.
-- Tout est calculé et vérifié par le serveur à partir des parties qu’il a enregistrées.
-- =====================================================================

update public.economie set reglages = reglages || '{"or_quete":15, "quetes_par_jour":3}'::jsonb where id = 1;

-- ---------- Catalogue des quêtes
create or replace function public.catalogue_quetes() returns jsonb
language sql immutable as $$
  select '[
    {"id":"parties3","texte":"Jouer 3 parties","cle":"parties","but":3},
    {"id":"victoires2","texte":"Gagner 2 parties","cle":"victoires","but":2},
    {"id":"creatures10","texte":"Poser 10 créatures","cle":"creatures","but":10},
    {"id":"sorts15","texte":"Jouer 15 sorts","cle":"sorts","but":15},
    {"id":"achats8","texte":"Acheter 8 cartes au marché","cle":"achats","but":8},
    {"id":"degats40","texte":"Infliger 40 dégâts à l’adversaire","cle":"degats","but":40},
    {"id":"soins20","texte":"Soigner 20 points de vie","cle":"soins","but":20},
    {"id":"pouvoir1","texte":"Utiliser 1 fois le pouvoir de votre divinité","cle":"pouvoirs","but":1},
    {"id":"vic_egy","texte":"Gagner une partie avec les Égyptiens","cle":"vic_egy","but":1},
    {"id":"vic_hin","texte":"Gagner une partie avec les Hindous","cle":"vic_hin","but":1},
    {"id":"vic_nor","texte":"Gagner une partie avec les Nordiques","cle":"vic_nor","but":1},
    {"id":"vic_gre","texte":"Gagner une partie avec les Grecs","cle":"vic_gre","but":1}
  ]'::jsonb
$$;

create table if not exists public.quetes_jour (
  joueur uuid not null references auth.users(id) on delete cascade,
  jour date not null default current_date,
  ids jsonb not null,
  reclamees jsonb not null default '[]'::jsonb,
  remplacee boolean not null default false,
  primary key (joueur, jour)
);
alter table public.quetes_jour enable row level security;   -- uniquement par les fonctions

-- Progression du jour pour une clé de quête
create or replace function public.progres_quete(u uuid, cle text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(case
    when cle = 'parties' then count(*)
    when cle = 'victoires' then count(*) filter (where victoire)
    when cle like 'vic\_%' then count(*) filter (where victoire and heros = substr(cle, 5))
    when cle = 'creatures' then sum(creatures) when cle = 'sorts' then sum(sorts) when cle = 'achats' then sum(achats)
    when cle = 'degats' then sum(degats) when cle = 'soins' then sum(soins) when cle = 'pouvoirs' then sum(pouvoirs)
  end, 0)::int
  from parties_jouees where joueur = u and mode in ('ia', 'enligne') and cree::date = current_date
$$;
revoke execute on function public.progres_quete(uuid, text) from public, anon, authenticated;

-- Les 3 quêtes du jour du joueur (tirées pour lui, puis mémorisées pour la journée)
create or replace function public.mes_quetes() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); q quetes_jour; cat jsonb := catalogue_quetes(); n int := coalesce((reglage('quetes_par_jour'))::int, 3);
begin
  if u is null then return '[]'::jsonb; end if;
  select * into q from quetes_jour where joueur = u and jour = current_date;
  if not found then
    insert into quetes_jour (joueur, jour, ids)
    select u, current_date, jsonb_agg(x->'id') from (select x from jsonb_array_elements(cat) x order by md5(u::text || current_date::text || (x->>'id')) limit n) t
    returning * into q;
  end if;
  return jsonb_build_object('remplacee', q.remplacee, 'gain', coalesce((reglage('or_quete'))::int, 15), 'quetes', (
    select coalesce(jsonb_agg(c || jsonb_build_object('progres', least(progres_quete(u, c->>'cle'), (c->>'but')::int), 'faite', q.reclamees ? (c->>'id')) order by i.ord), '[]'::jsonb)
    from jsonb_array_elements_text(q.ids) with ordinality i(id, ord) join jsonb_array_elements(cat) c on c->>'id' = i.id));
end $$;
grant execute on function public.mes_quetes() to authenticated;

create or replace function public.reclamer_quete_jour(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); q quetes_jour; c jsonb; gain int := coalesce((reglage('or_quete'))::int, 15);
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  perform mes_quetes();
  select * into q from quetes_jour where joueur = u and jour = current_date for update;
  if not (q.ids ? p_id) then
    perform noter_alerte(u, 'quete_inconnue', 'forte', jsonb_build_object('quete', p_id)); return jsonb_build_object('erreur', 'Quête inconnue.');
  end if;
  if q.reclamees ? p_id then return jsonb_build_object('erreur', 'Quête déjà récompensée.'); end if;
  select x into c from jsonb_array_elements(catalogue_quetes()) x where x->>'id' = p_id;
  if progres_quete(u, c->>'cle') < (c->>'but')::int then
    perform noter_alerte(u, 'quete_non_terminee', 'forte', jsonb_build_object('quete', c->>'texte', 'progres', progres_quete(u, c->>'cle'), 'objectif', c->'but'));
    return jsonb_build_object('erreur', 'Cette quête n’est pas encore terminée.');
  end if;
  update quetes_jour set reclamees = reclamees || to_jsonb(p_id) where joueur = u and jour = current_date;
  update profils set pieces_or = pieces_or + gain where id = u;
  return jsonb_build_object('gain', gain);
end $$;
grant execute on function public.reclamer_quete_jour(text) to authenticated;

-- Remplacer une quête non réclamée, une fois par jour
create or replace function public.remplacer_quete(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); q quetes_jour; nouvelle text;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  perform mes_quetes();
  select * into q from quetes_jour where joueur = u and jour = current_date for update;
  if q.remplacee then return jsonb_build_object('erreur', 'Vous avez déjà remplacé une quête aujourd’hui.'); end if;
  if not (q.ids ? p_id) or q.reclamees ? p_id then return jsonb_build_object('erreur', 'Cette quête ne peut pas être remplacée.'); end if;
  select x->>'id' into nouvelle from jsonb_array_elements(catalogue_quetes()) x where not (q.ids ? (x->>'id')) order by random() limit 1;
  update quetes_jour set ids = (select jsonb_agg(case when e = p_id then nouvelle else e end order by o) from jsonb_array_elements_text(q.ids) with ordinality t(e, o)), remplacee = true
  where joueur = u and jour = current_date;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.remplacer_quete(text) to authenticated;

-- L’ancienne quête unique n’existe plus
create or replace function public.reclamer_quete() returns int
language plpgsql security definer set search_path = public as $$
begin perform noter_alerte(auth.uid(), 'ancienne_version', 'faible', '{}'::jsonb); return -2; end $$;

-- ---------- Paquets offerts (réserve par type : « classique » ou un panthéon)
create table if not exists public.paquets_offerts (
  joueur uuid not null references auth.users(id) on delete cascade,
  type text not null,
  nb int not null default 0 check (nb >= 0),
  primary key (joueur, type)
);
alter table public.paquets_offerts enable row level security;
drop policy if exists paquets_offerts_lecture on public.paquets_offerts;
create policy paquets_offerts_lecture on public.paquets_offerts for select to authenticated using (joueur = auth.uid());

-- ---------- Trophées
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
    {"id":"champion_gre","paliers":[5,25,75,200],"pantheon":"gre"}
  ]'::jsonb
$$;

-- Valeur d’un trophée et seuil réel d’un rang (« -1 » : toutes les cartes au maximum d’exemplaires)
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
    else coalesce((s->'par_heros'->(th->>'pantheon')->>'victoires')::int, 0) end;
  if t = 'collection' and seuil = -1 then
    seuil := (select count(*) from catalogue where achetable and not promo);
    valeur := (select count(*) from collection c join catalogue k on k.carte = c.carte where c.joueur = u and k.achetable and not k.promo and c.nb >= max_copies(c.carte));
  end if;
end $$;
revoke execute on function public.valeur_trophee(uuid, text, jsonb, int) from public, anon, authenticated;

create table if not exists public.trophees_recompenses (
  joueur uuid not null references auth.users(id) on delete cascade,
  trophee text not null,
  palier int not null check (palier between 1 and 4),
  cree timestamptz not null default now(),
  primary key (joueur, trophee, palier)
);
alter table public.trophees_recompenses enable row level security;

-- Récompense d’un rang : or, ou paquets offerts
create or replace function public.recompense_trophee(t text, palier int) returns jsonb
language sql immutable as $$
  select case
    when t like 'champion\_%' then (case palier when 1 then '{"or":15}' when 2 then '{"or":30}'
                                    when 3 then jsonb_build_object('paquets', jsonb_build_array(substr(t, 10)))::text
                                    else jsonb_build_object('paquets', jsonb_build_array(substr(t, 10), 'classique'))::text end)::jsonb
    else (case palier when 1 then '{"or":15}' when 2 then '{"or":30}' when 3 then '{"or":60}' else '{"paquets":["classique"]}' end)::jsonb
  end
$$;

create or replace function public.mes_trophees() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s jsonb := mes_stats(); r jsonb := '[]'::jsonb; th jsonb; p int; v int; sl int; seuils jsonb; valeurs jsonb;
begin
  if u is null then return '[]'::jsonb; end if;
  for th in select x from jsonb_array_elements(catalogue_trophees()) x loop
    seuils := '[]'::jsonb; valeurs := '[]'::jsonb;
    for p in 1..4 loop
      select valeur, seuil into v, sl from valeur_trophee(u, th->>'id', s, p);
      seuils := seuils || to_jsonb(sl); valeurs := valeurs || to_jsonb(v);
    end loop;
    r := r || jsonb_build_object('id', th->>'id', 'valeur', valeurs->0, 'valeurs', valeurs, 'paliers', seuils, 'pantheon', th->'pantheon',
      'reclames', (select coalesce(jsonb_agg(palier order by palier), '[]'::jsonb) from trophees_recompenses where joueur = u and trophee = th->>'id'),
      'recompenses', (select jsonb_agg(recompense_trophee(th->>'id', q)) from generate_series(1, 4) q));
  end loop;
  return r;
end $$;
grant execute on function public.mes_trophees() to authenticated;

create or replace function public.reclamer_trophee(p_trophee text, p_palier int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); v int; sl int; rec jsonb; ty text;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  if not exists (select 1 from jsonb_array_elements(catalogue_trophees()) x where x->>'id' = p_trophee) or p_palier not between 1 and 4 then
    perform noter_alerte(u, 'trophee_inconnu', 'forte', jsonb_build_object('trophee', p_trophee, 'palier', p_palier)); return jsonb_build_object('erreur', 'Trophée inconnu.');
  end if;
  if exists (select 1 from trophees_recompenses where joueur = u and trophee = p_trophee and palier = p_palier) then
    return jsonb_build_object('erreur', 'Récompense déjà obtenue.');
  end if;
  select valeur, seuil into v, sl from valeur_trophee(u, p_trophee, mes_stats(), p_palier);
  if v < sl then
    perform noter_alerte(u, 'trophee_non_atteint', 'forte', jsonb_build_object('trophee', p_trophee, 'palier', p_palier, 'valeur', v, 'seuil', sl));
    return jsonb_build_object('erreur', 'Ce rang n’est pas encore atteint.');
  end if;
  insert into trophees_recompenses (joueur, trophee, palier) values (u, p_trophee, p_palier);
  rec := recompense_trophee(p_trophee, p_palier);
  if rec ? 'or' then update profils set pieces_or = pieces_or + (rec->>'or')::int where id = u; end if;
  for ty in select jsonb_array_elements_text(coalesce(rec->'paquets', '[]'::jsonb)) loop
    insert into paquets_offerts (joueur, type, nb) values (u, ty, 1) on conflict (joueur, type) do update set nb = paquets_offerts.nb + 1;
  end loop;
  return rec;
end $$;
grant execute on function public.reclamer_trophee(text, int) to authenticated;

-- ---------- Ouverture d’un paquet : acheté (or) ou offert (réserve)
drop function if exists public.ouvrir_paquet(text, text);
create or replace function public.ouvrir_paquet(p_faction text default null, p_booster text default null, p_offert boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); prix int := (reglage('prix_paquet'))::int; n int := (reglage('cartes_paquet'))::int;
        res text[] := '{}'; r text; c text; i int; a_rare boolean := false; b boosters; it record; gain int;
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  if p_offert and p_booster is not null then raise exception 'Les boosters spéciaux ne peuvent pas être offerts.'; end if;
  if p_booster is not null then
    select * into b from boosters where id = p_booster and actif;
    if not found then raise exception 'Ce booster n’est pas disponible.'; end if;
    create temporary table if not exists pool (genre text, ident text, rarete text) on commit drop;
    delete from pool;
    insert into pool select 'carte', k.carte, k.rarete from catalogue k where k.carte in (select jsonb_array_elements_text(b.cartes)) and k.achetable;
    insert into pool select 'variante', v.variante, v.rarete from catalogue_variantes v where v.variante in (select jsonb_array_elements_text(b.variantes));
    if not exists (select 1 from pool) then raise exception 'Ce booster est vide.'; end if;
  elsif not exists (select 1 from catalogue where achetable and not promo and (p_faction is null or faction = p_faction)) then
    raise exception 'Aucune carte disponible pour ce paquet.';
  end if;
  if p_offert then
    update paquets_offerts set nb = nb - 1 where joueur = u and type = coalesce(p_faction, 'classique') and nb > 0;
    if not found then
      perform noter_alerte(u, 'paquet_offert_inexistant', 'forte', jsonb_build_object('type', coalesce(p_faction, 'classique')));
      raise exception 'Vous n’avez pas de paquet offert de ce type.';
    end if;
  else
    update profils set pieces_or = pieces_or - prix where id = u and pieces_or >= prix;
    if not found then raise exception 'Or insuffisant pour acheter un paquet.'; end if;
  end if;
  for i in 1 .. n loop
    r := tirer_rarete();
    if i = n and not a_rare and r = 'commune' then r := 'rare'; end if;
    if p_booster is not null then
      select * into it from pool where rarete = r order by random() limit 1;
      if not found then select * into it from pool order by random() limit 1; end if;
      if it.rarete <> 'commune' then a_rare := true; end if;
      if it.genre = 'carte' then perform ajouter_carte(u, it.ident, 1); res := res || it.ident;
      else
        insert into variantes_joueur (joueur, variante) values (u, it.ident) on conflict do nothing;
        if found then res := res || ('v:' || it.ident);
        else gain := coalesce((reglage('encre_recyclage') ->> it.rarete)::int, 20); update profils set encre = encre + gain where id = u; res := res || ('v+:' || it.ident); end if;
      end if;
    else
      if r <> 'commune' then a_rare := true; end if;
      c := coalesce(tirer_carte(r, p_faction), tirer_carte('commune', p_faction), tirer_carte(r), tirer_carte('commune'));
      if c is not null then res := res || c; perform ajouter_carte(u, c, 1); end if;
    end if;
  end loop;
  return to_jsonb(res);
end $$;
grant execute on function public.ouvrir_paquet(text, text, boolean) to authenticated;
