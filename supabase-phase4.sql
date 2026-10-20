-- =====================================================================
-- PHASE 4 : collection, decks, or, paquets, encre et quête du jour
-- À exécuter une seule fois dans Supabase (SQL Editor, puis Run).
-- Le script peut être relancé sans danger : il ne supprime aucune donnée de joueur.
-- =====================================================================

-- ---------- Administrateurs (vous ajouterez votre identifiant plus tard)
create table if not exists public.admins (id uuid primary key);
alter table public.admins enable row level security;
drop policy if exists admins_lit on public.admins;
create policy admins_lit on public.admins for select to authenticated using (id = auth.uid());

create or replace function public.est_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where id = auth.uid())
$$;

-- ---------- Réglages de l'économie (modifiables depuis l'administration du jeu)
create table if not exists public.economie (
  id int primary key default 1 check (id = 1),
  reglages jsonb not null
);
insert into public.economie (id, reglages) values (1, '{"or_depart": 100, "or_victoire": 10, "or_defaite": 3, "plafond_or_jour": 100, "or_quete": 40, "prix_paquet": 100, "cartes_paquet": 5, "probabilites": {"commune": 0.72, "rare": 0.22, "epique": 0.05, "legendaire": 0.01}, "depart": {"commune": 20, "rare": 9, "epique": 1}, "encre_recyclage": {"commune": 5, "rare": 20, "epique": 100, "legendaire": 400}, "encre_fabrication": {"commune": 40, "rare": 100, "epique": 400, "legendaire": 1600}, "copies_max": 2, "copies_legendaire": 1}'::jsonb)
on conflict (id) do nothing;
alter table public.economie enable row level security;
drop policy if exists economie_lit on public.economie;
create policy economie_lit on public.economie for select to anon, authenticated using (true);

create or replace function public.reglage(cle text) returns jsonb
language sql stable set search_path = public as $$
  select reglages -> cle from economie where id = 1
$$;

-- ---------- Catalogue des cartes (identifiant et rareté, pour les tirages)
create table if not exists public.catalogue (
  carte text primary key,
  rarete text not null,
  achetable boolean not null default true
);
alter table public.catalogue enable row level security;
drop policy if exists catalogue_lit on public.catalogue;
create policy catalogue_lit on public.catalogue for select to anon, authenticated using (true);

insert into public.catalogue (carte, rarete, achetable) values
  ('piece', 'commune', false),
  ('rubis', 'commune', false),
  ('dague', 'commune', false),
  ('epee', 'commune', false),
  ('pierre', 'commune', false),
  ('porteur_jarres', 'commune', true),
  ('gardien_temple', 'commune', true),
  ('scarabee', 'commune', true),
  ('garde_anubis', 'commune', true),
  ('pretresse', 'commune', true),
  ('archer_nubie', 'commune', true),
  ('chameau', 'commune', true),
  ('sphinx', 'commune', true),
  ('embaumeur', 'rare', true),
  ('chat_bastet', 'rare', true),
  ('pretre_thot', 'rare', true),
  ('char_ramses', 'rare', true),
  ('sentinelle', 'rare', true),
  ('vizir', 'epique', true),
  ('colosse', 'epique', true),
  ('pretre_osiris', 'epique', true),
  ('pharaon', 'legendaire', true),
  ('scribe', 'commune', true),
  ('pain_nil', 'commune', true),
  ('hathor', 'commune', true),
  ('sekhmet', 'commune', true),
  ('papyrus', 'commune', true),
  ('jugement', 'rare', true),
  ('benediction', 'rare', true),
  ('crue', 'rare', true),
  ('tempete_sable', 'epique', true),
  ('momification', 'epique', true),
  ('oeil_ra', 'legendaire', true),
  ('khepesh', 'commune', true),
  ('fleau', 'rare', true),
  ('singe_temple', 'commune', true),
  ('apsara', 'commune', true),
  ('marchand_epices', 'commune', true),
  ('cobra', 'commune', true),
  ('elephant', 'commune', true),
  ('yogi', 'commune', true),
  ('tigre', 'commune', true),
  ('garde_rajah', 'commune', true),
  ('naga', 'rare', true),
  ('danseuse', 'rare', true),
  ('caravanier', 'rare', true),
  ('rakshasa', 'rare', true),
  ('elephant_maharaja', 'rare', true),
  ('deva', 'epique', true),
  ('roi_nagas', 'epique', true),
  ('architecte', 'epique', true),
  ('garuda', 'legendaire', true),
  ('marchand', 'commune', true),
  ('epices', 'commune', true),
  ('bazar', 'commune', true),
  ('tambours', 'commune', true),
  ('offrandes', 'commune', true),
  ('mantra', 'rare', true),
  ('don_lakshmi', 'rare', true),
  ('roue_karma', 'rare', true),
  ('kubera', 'epique', true),
  ('tresor_rajahs', 'epique', true),
  ('himalaya', 'legendaire', true),
  ('chakram', 'commune', true),
  ('trident', 'rare', true),
  ('eclaireur', 'commune', true),
  ('berserker', 'commune', true),
  ('porte_bouclier', 'commune', true),
  ('loup_neiges', 'commune', true),
  ('skalde', 'commune', true),
  ('pillard', 'commune', true),
  ('ours', 'commune', true),
  ('huscarl', 'commune', true),
  ('corbeau', 'rare', true),
  ('valkyrie', 'rare', true),
  ('geant_givre', 'rare', true),
  ('ulfhednar', 'rare', true),
  ('vierge_bouclier', 'rare', true),
  ('jarl', 'epique', true),
  ('troll', 'epique', true),
  ('meute_fenrir', 'epique', true),
  ('tempete', 'legendaire', true),
  ('hydromel', 'commune', true),
  ('butin', 'commune', true),
  ('cri', 'commune', true),
  ('rune_force', 'commune', true),
  ('raid', 'commune', true),
  ('colere_thor', 'rare', true),
  ('fureur', 'rare', true),
  ('grand_hiver', 'rare', true),
  ('festin_valhalla', 'epique', true),
  ('corne_heimdall', 'epique', true),
  ('ragnarok', 'legendaire', true),
  ('hache', 'commune', true),
  ('marteau', 'rare', true),
  ('messager', 'commune', true),
  ('satyre', 'commune', true),
  ('archer_crete', 'commune', true),
  ('hoplite', 'commune', true),
  ('centaure', 'commune', true),
  ('phalangiste', 'commune', true),
  ('harpie', 'commune', true),
  ('cyclope', 'commune', true),
  ('pegase', 'rare', true),
  ('sirene', 'rare', true),
  ('minotaure', 'rare', true),
  ('meduse', 'rare', true),
  ('cerbere', 'rare', true),
  ('heracles', 'epique', true),
  ('talos', 'epique', true),
  ('chimere', 'epique', true),
  ('hydre', 'legendaire', true),
  ('oracle', 'commune', true),
  ('amphore', 'commune', true),
  ('philosophe', 'commune', true),
  ('javelots', 'commune', true),
  ('symposium', 'commune', true),
  ('sagesse', 'rare', true),
  ('ruse', 'rare', true),
  ('foudre', 'rare', true),
  ('festin_olympe', 'epique', true),
  ('travaux', 'epique', true),
  ('pandore', 'legendaire', true),
  ('glaive', 'commune', true),
  ('lance', 'rare', true),
  ('momie', 'commune', false),
  ('esprit', 'commune', false),
  ('loup', 'commune', false),
  ('tete', 'commune', false)
on conflict (carte) do update set rarete = excluded.rarete, achetable = excluded.achetable;

-- ---------- Profil, collection et decks de chaque joueur
create table if not exists public.profils (
  id uuid primary key references auth.users(id) on delete cascade,
  pieces_or int not null default 0 check (pieces_or >= 0),
  encre int not null default 0 check (encre >= 0),
  jour date,
  or_jour int not null default 0,
  quete_jour date,
  cree timestamptz not null default now()
);
alter table public.profils enable row level security;
drop policy if exists profils_lit on public.profils;
create policy profils_lit on public.profils for select to authenticated using (id = auth.uid());

create table if not exists public.collection (
  joueur uuid not null references auth.users(id) on delete cascade,
  carte text not null,
  nb int not null default 0 check (nb >= 0),
  primary key (joueur, carte)
);
alter table public.collection enable row level security;
drop policy if exists collection_lit on public.collection;
create policy collection_lit on public.collection for select to authenticated using (joueur = auth.uid());

create table if not exists public.decks (
  id uuid primary key default gen_random_uuid(),
  joueur uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nom text not null,
  cartes jsonb not null default '[]'::jsonb,
  maj timestamptz not null default now()
);
alter table public.decks enable row level security;
drop policy if exists decks_lit on public.decks;
drop policy if exists decks_cree on public.decks;
drop policy if exists decks_modifie on public.decks;
drop policy if exists decks_supprime on public.decks;
create policy decks_lit on public.decks for select to authenticated using (joueur = auth.uid());
create policy decks_cree on public.decks for insert to authenticated with check (joueur = auth.uid());
create policy decks_modifie on public.decks for update to authenticated using (joueur = auth.uid()) with check (joueur = auth.uid());
create policy decks_supprime on public.decks for delete to authenticated using (joueur = auth.uid());

create or replace function public.limite_decks() returns trigger
language plpgsql set search_path = public as $$
begin
  if (select count(*) from decks where joueur = new.joueur) >= 9 then
    raise exception 'Vous avez déjà 9 decks : supprimez-en un pour en créer un nouveau.';
  end if;
  return new;
end $$;
drop trigger if exists limite_decks on public.decks;
create trigger limite_decks before insert on public.decks for each row execute function public.limite_decks();

-- ---------- Outils internes
create or replace function public.tirer_carte(r text) returns text
language sql volatile set search_path = public as $$
  select carte from catalogue where rarete = r and achetable order by random() limit 1
$$;

create or replace function public.tirer_rarete() returns text
language plpgsql volatile set search_path = public as $$
declare p jsonb := reglage('probabilites'); x float := random(); cumul float := 0; r text;
begin
  foreach r in array array['legendaire','epique','rare','commune'] loop
    cumul := cumul + coalesce((p ->> r)::float, 0);
    if x < cumul then return r; end if;
  end loop;
  return 'commune';
end $$;

create or replace function public.ajouter_carte(j uuid, c text, n int) returns void
language sql set search_path = public as $$
  insert into collection (joueur, carte, nb) values (j, c, n)
  on conflict (joueur, carte) do update set nb = collection.nb + excluded.nb
$$;

create or replace function public.max_copies(c text) returns int
language sql stable set search_path = public as $$
  select case when rarete = 'legendaire' then coalesce((reglage('copies_legendaire'))::int, 1)
              else coalesce((reglage('copies_max'))::int, 2) end
  from catalogue where carte = c
$$;

-- ---------- Actions des joueurs
-- Premier passage : création du profil et des 30 cartes offertes
create or replace function public.initialiser_joueur() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := reglage('depart'); r text; i int; c text; essai int;
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  if exists (select 1 from profils where id = u) then return jsonb_build_object('nouveau', false); end if;
  if not exists (select 1 from catalogue where achetable) then raise exception 'Le catalogue de cartes est vide.'; end if;
  insert into profils (id, pieces_or) values (u, coalesce((reglage('or_depart'))::int, 0));
  for r in select key from jsonb_each_text(d) loop
    for i in 1 .. coalesce((d ->> r)::int, 0) loop
      -- jamais plus d'exemplaires qu'un deck ne peut en contenir
      for essai in 1 .. 20 loop
        c := tirer_carte(r);
        exit when c is null or coalesce((select nb from collection where joueur = u and carte = c), 0) < max_copies(c);
      end loop;
      if c is not null then perform ajouter_carte(u, c, 1); end if;
    end loop;
  end loop;
  return jsonb_build_object('nouveau', true);
end $$;

-- Paquet : le tirage se fait ici, sur le serveur, jamais dans le navigateur
create or replace function public.ouvrir_paquet() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); prix int := (reglage('prix_paquet'))::int; n int := (reglage('cartes_paquet'))::int;
        res text[] := '{}'; r text; c text; i int; a_rare boolean := false;
begin
  if not exists (select 1 from catalogue where achetable) then raise exception 'Le catalogue de cartes est vide.'; end if;
  update profils set pieces_or = pieces_or - prix where id = u and pieces_or >= prix;
  if not found then raise exception 'Or insuffisant pour acheter un paquet.'; end if;
  for i in 1 .. n loop
    r := tirer_rarete();
    if i = n and not a_rare and r = 'commune' then r := 'rare'; end if;
    if r <> 'commune' then a_rare := true; end if;
    c := coalesce(tirer_carte(r), tirer_carte('commune'));
    if c is not null then res := res || c; perform ajouter_carte(u, c, 1); end if;
  end loop;
  return to_jsonb(res);
end $$;

-- Fin de partie : or de victoire ou de défaite, avec plafond quotidien
create or replace function public.fin_partie(victoire boolean) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); p profils; gain int; plafond int := coalesce((reglage('plafond_or_jour'))::int, 100);
begin
  select * into p from profils where id = u for update;
  if not found then raise exception 'Profil introuvable.'; end if;
  if p.jour is distinct from current_date then p.or_jour := 0; end if;
  gain := case when victoire then (reglage('or_victoire'))::int else (reglage('or_defaite'))::int end;
  gain := greatest(0, least(gain, plafond - p.or_jour));
  update profils set pieces_or = pieces_or + gain, or_jour = p.or_jour + gain, jour = current_date where id = u;
  return gain;
end $$;

-- Quête du jour : une récompense par jour
create or replace function public.reclamer_quete() returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); gain int := coalesce((reglage('or_quete'))::int, 40);
begin
  update profils set pieces_or = pieces_or + gain, quete_jour = current_date
  where id = u and quete_jour is distinct from current_date;
  if not found then raise exception 'La quête du jour a déjà été récompensée.'; end if;
  return gain;
end $$;

-- Recycler un exemplaire en trop en encre
create or replace function public.recycler(c text) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); v_nb int; v_max int := max_copies(c); r text; gain int;
begin
  select rarete into r from catalogue where carte = c;
  if r is null then raise exception 'Carte inconnue.'; end if;
  select nb into v_nb from collection where joueur = u and carte = c for update;
  if coalesce(v_nb, 0) <= v_max then raise exception 'Seuls les exemplaires en trop peuvent être recyclés.'; end if;
  gain := (reglage('encre_recyclage') ->> r)::int;
  update collection set nb = nb - 1 where joueur = u and carte = c;
  update profils set encre = encre + gain where id = u;
  return gain;
end $$;

-- Fabriquer une carte avec de l'encre
create or replace function public.fabriquer(c text) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); v_nb int; v_max int := max_copies(c); r text; cout int;
begin
  select rarete into r from catalogue where carte = c and achetable;
  if r is null then raise exception 'Cette carte ne peut pas être fabriquée.'; end if;
  select coalesce(nb, 0) into v_nb from collection where joueur = u and carte = c;
  if coalesce(v_nb, 0) >= v_max then raise exception 'Vous avez déjà le nombre maximum d’exemplaires.'; end if;
  cout := (reglage('encre_fabrication') ->> r)::int;
  update profils set encre = encre - cout where id = u and encre >= cout;
  if not found then raise exception 'Encre insuffisante.'; end if;
  perform ajouter_carte(u, c, 1);
  return cout;
end $$;

-- ---------- Actions réservées à l'administrateur
create or replace function public.admin_maj_catalogue(cartes jsonb) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  delete from catalogue where true;
  insert into catalogue (carte, rarete, achetable)
  select key, coalesce(value ->> 'rarete', 'commune'),
         not (coalesce((value ->> 'depart')::boolean, false) or coalesce((value ->> 'base')::boolean, false) or coalesce((value ->> 'jeton')::boolean, false))
  from jsonb_each(cartes);
  return (select count(*) from catalogue);
end $$;

create or replace function public.admin_maj_economie(r jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  update economie set reglages = r where id = 1;
end $$;

create or replace function public.admin_crediter(p_or int, p_encre int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  update profils set pieces_or = greatest(0, pieces_or + p_or), encre = greatest(0, encre + p_encre) where id = auth.uid();
end $$;

-- Les fonctions internes ne sont pas appelables directement par les joueurs
revoke execute on function public.ajouter_carte(uuid, text, int) from public, anon, authenticated;
revoke execute on function public.tirer_carte(text) from public, anon, authenticated;
revoke execute on function public.tirer_rarete() from public, anon, authenticated;
