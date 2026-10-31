-- =====================================================================
-- ADMINISTRATION : fiche complète d’un joueur, don de cartes et d’illustrations
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après les autres scripts.
-- =====================================================================

-- Statistiques d’un joueur donné (même calcul que « mes_stats »)
create or replace function public.stats_de(u uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with p as (select * from parties_jouees where joueur = u)
  select jsonb_build_object(
    'parties', (select count(*) from p),
    'victoires', (select count(*) from p where victoire),
    'degats', (select coalesce(sum(degats), 0) from p),
    'soins', (select coalesce(sum(soins), 0) from p),
    'creatures', (select coalesce(sum(creatures), 0) from p),
    'sorts', (select coalesce(sum(sorts), 0) from p),
    'achats', (select coalesce(sum(achats), 0) from p),
    'pouvoirs', (select coalesce(sum(pouvoirs), 0) from p),
    'en_ligne', (select count(*) from p where mode = 'enligne'),
    'victoires_en_ligne', (select count(*) from p where mode = 'enligne' and victoire),
    'serie_max', (select coalesce(max(n), 0) from (
        select count(*) n from (select victoire, sum(case when victoire then 0 else 1 end) over (order by cree, id) g from p) s
        where victoire group by g) t),
    'par_heros', (select coalesce(jsonb_object_agg(heros, jsonb_build_object('parties', n, 'victoires', v)), '{}'::jsonb)
                  from (select heros, count(*) n, count(*) filter (where victoire) v from p where heros is not null group by heros) x)
  )
$$;
revoke execute on function public.stats_de(uuid) from public, anon, authenticated;

create or replace function public.admin_fiche_joueur(p_joueur uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (select jsonb_build_object(
    'id', p.id, 'pseudo', p.pseudo, 'email', u.email, 'titre', p.titre, 'or', p.pieces_or, 'encre', p.encre,
    'cree', p.cree, 'derniere_vue', p.derniere_vue,
    'stats', stats_de(p_joueur),
    'collection', (select coalesce(jsonb_object_agg(carte, nb), '{}'::jsonb) from collection where joueur = p_joueur and nb > 0),
    'variantes', (select coalesce(jsonb_agg(variante order by obtenue), '[]'::jsonb) from variantes_joueur where joueur = p_joueur),
    'decks', (select coalesce(jsonb_agg(jsonb_build_object('nom', nom, 'cartes', jsonb_array_length(cartes)) order by nom), '[]'::jsonb) from decks where joueur = p_joueur),
    'paquets_offerts', (select coalesce(jsonb_object_agg(type, nb), '{}'::jsonb) from paquets_offerts where joueur = p_joueur and nb > 0),
    'alertes', (select count(*) from alertes where joueur = p_joueur),
    'dernieres', (select coalesce(jsonb_agg(x order by x.cree desc), '[]'::jsonb) from (
        select cree, mode, victoire, heros, heros_adverse, tours, degats, duree_s from parties_jouees where joueur = p_joueur order by cree desc limit 10) x))
    from profils p left join auth.users u on u.id = p.id where p.id = p_joueur);
end $$;
grant execute on function public.admin_fiche_joueur(uuid) to authenticated;

-- Ajouter (nombre positif) ou retirer (nombre négatif) des exemplaires d’une carte
create or replace function public.admin_donner_carte(p_joueur uuid, p_carte text, p_nb int) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if not exists (select 1 from catalogue where carte = p_carte) then raise exception 'Carte inconnue du catalogue du serveur (envoyez le catalogue).'; end if;
  if p_nb > 0 then perform ajouter_carte(p_joueur, p_carte, p_nb);
  else update collection set nb = greatest(0, nb + p_nb) where joueur = p_joueur and carte = p_carte; end if;
  select coalesce(nb, 0) into n from collection where joueur = p_joueur and carte = p_carte;
  return coalesce(n, 0);
end $$;
grant execute on function public.admin_donner_carte(uuid, text, int) to authenticated;

-- Offrir ou retirer une illustration alternative
create or replace function public.admin_donner_variante(p_joueur uuid, p_variante text, p_donner boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if p_donner then
    if not exists (select 1 from catalogue_variantes where variante = p_variante) then raise exception 'Illustration inconnue du serveur (envoyez le catalogue).'; end if;
    insert into variantes_joueur (joueur, variante) values (p_joueur, p_variante) on conflict do nothing;
  else
    delete from variantes_joueur where joueur = p_joueur and variante = p_variante;
  end if;
  return true;
end $$;
grant execute on function public.admin_donner_variante(uuid, text, boolean) to authenticated;
