-- =====================================================================
-- ILLUSTRATIONS ALTERNATIVES, CARTES PROMOTIONNELLES ET BOOSTERS SPÉCIAUX
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-surveillance.sql.
-- Ensuite, dans l’administration du site : onglet Serveur, « Envoyer le catalogue ».
-- =====================================================================

-- ---------- Cartes promotionnelles : absentes des boosters principal et de panthéon, non fabricables
alter table public.catalogue add column if not exists promo boolean not null default false;

-- ---------- Illustrations alternatives (une variante appartient à une carte de base)
create table if not exists public.catalogue_variantes (
  variante text primary key,
  carte text not null,
  rarete text not null
);
alter table public.catalogue_variantes enable row level security;
drop policy if exists catalogue_variantes_lecture on public.catalogue_variantes;
create policy catalogue_variantes_lecture on public.catalogue_variantes for select using (true);

-- Variantes débloquées par chaque joueur (une fois pour toutes) et celle qu’il préfère afficher
create table if not exists public.variantes_joueur (
  joueur uuid not null references auth.users(id) on delete cascade,
  variante text not null,
  choisie boolean not null default false,
  obtenue timestamptz not null default now(),
  primary key (joueur, variante)
);
alter table public.variantes_joueur enable row level security;
drop policy if exists variantes_joueur_lecture on public.variantes_joueur;
create policy variantes_joueur_lecture on public.variantes_joueur for select to authenticated using (joueur = auth.uid());

-- ---------- Boosters spéciaux : contenu choisi par l’administrateur
create table if not exists public.boosters (
  id text primary key,
  nom text not null,
  actif boolean not null default true,
  cartes jsonb not null default '[]'::jsonb,
  variantes jsonb not null default '[]'::jsonb
);
alter table public.boosters enable row level security;
drop policy if exists boosters_lecture on public.boosters;
create policy boosters_lecture on public.boosters for select using (true);

-- ---------- Tirages : le booster principal et ceux de panthéon excluent les cartes promotionnelles
drop function if exists public.tirer_carte(text, text);
create or replace function public.tirer_carte(r text, f text default null) returns text
language sql volatile set search_path = public as $$
  select carte from catalogue where rarete = r and achetable and not promo and (f is null or faction = f) order by random() limit 1
$$;
revoke execute on function public.tirer_carte(text, text) from public, anon, authenticated;

-- ---------- Ouverture d’un paquet : principal, de panthéon (p_faction) ou spécial (p_booster)
-- Renvoie la liste des tirages : un identifiant de carte, « v:variante » (nouvelle illustration)
-- ou « v+:variante » (illustration déjà possédée, convertie en encre).
drop function if exists public.ouvrir_paquet(text);
drop function if exists public.ouvrir_paquet(text, text);
create or replace function public.ouvrir_paquet(p_faction text default null, p_booster text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); prix int := (reglage('prix_paquet'))::int; n int := (reglage('cartes_paquet'))::int;
        res text[] := '{}'; r text; c text; i int; a_rare boolean := false; b boosters; it record; gain int;
begin
  if u is null then raise exception 'Connexion requise.'; end if;
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
  update profils set pieces_or = pieces_or - prix where id = u and pieces_or >= prix;
  if not found then raise exception 'Or insuffisant pour acheter un paquet.'; end if;
  for i in 1 .. n loop
    r := tirer_rarete();
    if i = n and not a_rare and r = 'commune' then r := 'rare'; end if;
    if p_booster is not null then
      -- Même chances de rareté ; si le booster n’a rien de cette rareté, n’importe quel élément du booster
      select * into it from pool where rarete = r order by random() limit 1;
      if not found then select * into it from pool order by random() limit 1; end if;
      if it.rarete <> 'commune' then a_rare := true; end if;
      if it.genre = 'carte' then
        perform ajouter_carte(u, it.ident, 1); res := res || it.ident;
      else
        insert into variantes_joueur (joueur, variante) values (u, it.ident) on conflict do nothing;
        if found then res := res || ('v:' || it.ident);
        else
          gain := coalesce((reglage('encre_recyclage') ->> it.rarete)::int, 20);
          update profils set encre = encre + gain where id = u;
          res := res || ('v+:' || it.ident);
        end if;
      end if;
    else
      if r <> 'commune' then a_rare := true; end if;
      c := coalesce(tirer_carte(r, p_faction), tirer_carte('commune', p_faction), tirer_carte(r), tirer_carte('commune'));
      if c is not null then res := res || c; perform ajouter_carte(u, c, 1); end if;
    end if;
  end loop;
  return to_jsonb(res);
end $$;
grant execute on function public.ouvrir_paquet(text, text) to authenticated;

-- ---------- Les cartes promotionnelles ne se fabriquent pas et ne se recyclent pas
create or replace function public.fabriquer(c text) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); v_nb int; v_max int := max_copies(c); r text; cout int;
begin
  select rarete into r from catalogue where carte = c and achetable and not promo;
  if r is null then raise exception 'Cette carte ne peut pas être fabriquée.'; end if;
  select coalesce(nb, 0) into v_nb from collection where joueur = u and carte = c;
  if coalesce(v_nb, 0) >= v_max then raise exception 'Vous avez déjà le nombre maximum d’exemplaires.'; end if;
  cout := (reglage('encre_fabrication') ->> r)::int;
  update profils set encre = encre - cout where id = u and encre >= cout;
  if not found then raise exception 'Encre insuffisante.'; end if;
  perform ajouter_carte(u, c, 1);
  return cout;
end $$;
create or replace function public.recycler(c text) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); v_nb int; v_max int := max_copies(c); r text; gain int;
begin
  select rarete into r from catalogue where carte = c and not promo;
  if r is null then raise exception 'Cette carte ne peut pas être recyclée.'; end if;
  select nb into v_nb from collection where joueur = u and carte = c for update;
  if coalesce(v_nb, 0) <= v_max then raise exception 'Seuls les exemplaires en trop peuvent être recyclés.'; end if;
  gain := (reglage('encre_recyclage') ->> r)::int;
  update collection set nb = nb - 1 where joueur = u and carte = c;
  update profils set encre = encre + gain where id = u;
  return gain;
end $$;

-- ---------- Choix de l’illustration affichée pour une carte (null : l’illustration d’origine)
create or replace function public.choisir_variante(p_carte text, p_variante text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  if p_variante is not null and not exists (
      select 1 from variantes_joueur vj join catalogue_variantes v on v.variante = vj.variante
      where vj.joueur = u and vj.variante = p_variante and v.carte = p_carte) then
    perform noter_alerte(u, 'variante_non_possedee', 'forte', jsonb_build_object('carte', p_carte, 'variante', p_variante));
    return;
  end if;
  update variantes_joueur vj set choisie = coalesce(vj.variante = p_variante, false)
  from catalogue_variantes v where v.variante = vj.variante and v.carte = p_carte and vj.joueur = u;
end $$;
grant execute on function public.choisir_variante(text, text) to authenticated;

-- ---------- Envoi depuis l’administration : catalogue (avec la case « promotionnelle »), variantes et boosters
create or replace function public.admin_maj_catalogue(cartes jsonb) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  delete from catalogue where true;
  insert into catalogue (carte, rarete, achetable, faction, promo)
  select key, coalesce(value ->> 'rarete', 'commune'),
         not (coalesce((value ->> 'depart')::boolean, false) or coalesce((value ->> 'base')::boolean, false) or coalesce((value ->> 'jeton')::boolean, false)),
         nullif(value ->> 'faction', ''), coalesce((value ->> 'promo')::boolean, false)
  from jsonb_each(cartes);
  return (select count(*) from catalogue);
end $$;

create or replace function public.admin_maj_contenu(p_variantes jsonb, p_boosters jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  delete from catalogue_variantes where true;
  insert into catalogue_variantes (variante, carte, rarete)
  select v.key, v.value ->> 'carte', coalesce(k.rarete, 'rare')
  from jsonb_each(coalesce(p_variantes, '{}'::jsonb)) v left join catalogue k on k.carte = v.value ->> 'carte'
  where v.value ->> 'carte' is not null;
  delete from boosters where true;
  insert into boosters (id, nom, actif, cartes, variantes)
  select b.key, left(coalesce(b.value ->> 'nom', 'Booster'), 60), coalesce((b.value ->> 'actif')::boolean, true),
         case when jsonb_typeof(b.value -> 'cartes') = 'array' then b.value -> 'cartes' else '[]'::jsonb end,
         case when jsonb_typeof(b.value -> 'variantes') = 'array' then b.value -> 'variantes' else '[]'::jsonb end
  from jsonb_each(coalesce(p_boosters, '{}'::jsonb)) b;
  return jsonb_build_object('variantes', (select count(*) from catalogue_variantes), 'boosters', (select count(*) from boosters));
end $$;
grant execute on function public.admin_maj_contenu(jsonb, jsonb) to authenticated;
