-- =====================================================================
-- PAQUETS PAR FACTION
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-phase4.sql.
-- Ajoute la faction au catalogue du serveur et permet d'ouvrir un paquet
-- limité à une faction, avec le même prix et les mêmes chances.
-- =====================================================================

-- 1. La faction de chaque carte (remplie d'après config.json sur GitHub)
alter table public.catalogue add column if not exists faction text;
update public.catalogue c set faction = v.faction
from (values
  ('piece', null),
  ('rubis', null),
  ('dague', null),
  ('epee', null),
  ('pierre', null),
  ('porteur_jarres', 'egy'),
  ('gardien_temple', 'egy'),
  ('scarabee', 'egy'),
  ('garde_anubis', 'egy'),
  ('pretresse', 'egy'),
  ('archer_nubie', 'egy'),
  ('chameau', 'egy'),
  ('sphinx', 'egy'),
  ('embaumeur', 'egy'),
  ('chat_bastet', 'egy'),
  ('pretre_thot', 'egy'),
  ('char_ramses', 'egy'),
  ('sentinelle', 'egy'),
  ('vizir', 'egy'),
  ('colosse', 'egy'),
  ('pretre_osiris', 'egy'),
  ('pharaon', 'egy'),
  ('scribe', 'egy'),
  ('pain_nil', 'egy'),
  ('hathor', 'egy'),
  ('sekhmet', 'egy'),
  ('papyrus', 'egy'),
  ('jugement', 'egy'),
  ('benediction', 'egy'),
  ('crue', 'egy'),
  ('tempete_sable', 'egy'),
  ('momification', 'egy'),
  ('oeil_ra', 'egy'),
  ('khepesh', 'egy'),
  ('fleau', 'egy'),
  ('singe_temple', 'hin'),
  ('apsara', 'hin'),
  ('marchand_epices', 'hin'),
  ('cobra', 'hin'),
  ('elephant', 'hin'),
  ('yogi', 'hin'),
  ('tigre', 'hin'),
  ('garde_rajah', 'hin'),
  ('naga', 'hin'),
  ('danseuse', 'hin'),
  ('caravanier', 'hin'),
  ('rakshasa', 'hin'),
  ('elephant_maharaja', 'hin'),
  ('deva', 'hin'),
  ('roi_nagas', 'hin'),
  ('architecte', 'hin'),
  ('garuda', 'hin'),
  ('marchand', 'hin'),
  ('epices', 'hin'),
  ('bazar', 'hin'),
  ('tambours', 'hin'),
  ('offrandes', 'hin'),
  ('mantra', 'hin'),
  ('don_lakshmi', 'hin'),
  ('roue_karma', 'hin'),
  ('kubera', 'hin'),
  ('tresor_rajahs', 'hin'),
  ('himalaya', 'hin'),
  ('chakram', 'hin'),
  ('trident', 'hin'),
  ('eclaireur', 'nor'),
  ('berserker', 'nor'),
  ('porte_bouclier', 'nor'),
  ('loup_neiges', 'nor'),
  ('skalde', 'nor'),
  ('pillard', 'nor'),
  ('ours', 'nor'),
  ('huscarl', 'nor'),
  ('corbeau', 'nor'),
  ('valkyrie', 'nor'),
  ('geant_givre', 'nor'),
  ('ulfhednar', 'nor'),
  ('vierge_bouclier', 'nor'),
  ('jarl', 'nor'),
  ('troll', 'nor'),
  ('meute_fenrir', 'nor'),
  ('tempete', 'nor'),
  ('hydromel', 'nor'),
  ('butin', 'nor'),
  ('cri', 'nor'),
  ('rune_force', 'nor'),
  ('raid', 'nor'),
  ('colere_thor', 'nor'),
  ('fureur', 'nor'),
  ('grand_hiver', 'nor'),
  ('festin_valhalla', 'nor'),
  ('corne_heimdall', 'nor'),
  ('ragnarok', 'nor'),
  ('hache', 'nor'),
  ('marteau', 'nor'),
  ('messager', 'gre'),
  ('satyre', 'gre'),
  ('archer_crete', 'gre'),
  ('hoplite', 'gre'),
  ('centaure', 'gre'),
  ('phalangiste', 'gre'),
  ('harpie', 'gre'),
  ('cyclope', 'gre'),
  ('pegase', 'gre'),
  ('sirene', 'gre'),
  ('minotaure', 'gre'),
  ('meduse', 'gre'),
  ('cerbere', 'gre'),
  ('heracles', 'gre'),
  ('talos', 'gre'),
  ('chimere', 'gre'),
  ('hydre', 'gre'),
  ('oracle', 'gre'),
  ('amphore', 'gre'),
  ('philosophe', 'gre'),
  ('javelots', 'gre'),
  ('symposium', 'gre'),
  ('sagesse', 'gre'),
  ('ruse', 'gre'),
  ('foudre', 'gre'),
  ('festin_olympe', 'gre'),
  ('travaux', 'gre'),
  ('pandore', 'gre'),
  ('glaive', 'gre'),
  ('lance', 'gre'),
  ('momie', 'egy'),
  ('esprit', 'hin'),
  ('loup', 'nor'),
  ('tete', 'gre')
) as v(carte, faction)
where c.carte = v.carte;

-- 2. Tirage d'une carte, éventuellement limité à une faction
drop function if exists public.tirer_carte(text);
create or replace function public.tirer_carte(r text, f text default null) returns text
language sql volatile set search_path = public as $$
  select carte from catalogue where rarete = r and achetable and (f is null or faction = f) order by random() limit 1
$$;
revoke execute on function public.tirer_carte(text, text) from public, anon, authenticated;

-- 3. Ouverture d'un paquet : classique (sans faction) ou d'une faction
drop function if exists public.ouvrir_paquet();
create or replace function public.ouvrir_paquet(p_faction text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); prix int := (reglage('prix_paquet'))::int; n int := (reglage('cartes_paquet'))::int;
        res text[] := '{}'; r text; c text; i int; a_rare boolean := false;
begin
  if not exists (select 1 from catalogue where achetable and (p_faction is null or faction = p_faction)) then
    raise exception 'Aucune carte disponible pour ce paquet.';
  end if;
  update profils set pieces_or = pieces_or - prix where id = u and pieces_or >= prix;
  if not found then raise exception 'Or insuffisant pour acheter un paquet.'; end if;
  for i in 1 .. n loop
    r := tirer_rarete();
    if i = n and not a_rare and r = 'commune' then r := 'rare'; end if;
    if r <> 'commune' then a_rare := true; end if;
    c := coalesce(tirer_carte(r, p_faction), tirer_carte('commune', p_faction), tirer_carte(r), tirer_carte('commune'));
    if c is not null then res := res || c; perform ajouter_carte(u, c, 1); end if;
  end loop;
  return to_jsonb(res);
end $$;
grant execute on function public.ouvrir_paquet(text) to authenticated;

-- 4. L'envoi du catalogue depuis l'administration transmet aussi la faction
create or replace function public.admin_maj_catalogue(cartes jsonb) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  delete from catalogue where true;
  insert into catalogue (carte, rarete, achetable, faction)
  select key, coalesce(value ->> 'rarete', 'commune'),
         not (coalesce((value ->> 'depart')::boolean, false) or coalesce((value ->> 'base')::boolean, false) or coalesce((value ->> 'jeton')::boolean, false)),
         nullif(value ->> 'faction', '')
  from jsonb_each(cartes);
  return (select count(*) from catalogue);
end $$;
