-- =====================================================================
-- CORRECTIF DES CADEAUX AUTOMATIQUES : les parties de 2 contre 2 comptent aussi
-- À exécuter une fois dans Supabase (SQL Editor, puis Run). Il peut être relancé sans risque.
-- Les paliers étaient calculés sur les seules parties contre l’ordinateur et en ligne.
-- Après l’exécution, cliquez sur « Envoyer maintenant aux joueurs ayant déjà atteint ces paliers »
-- (onglet Cadeaux automatiques) pour servir ceux qui les avaient atteints grâce au 2 contre 2.
-- =====================================================================
create or replace function public.envoyer_paliers_parties(u uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int; p paliers_parties; pseudo text; envoyes int := 0;
begin
  select count(*) into n from parties_jouees where joueur = u and mode in ('ia', 'enligne', '2v2');
  select coalesce(pr.pseudo, 'aventurier') into pseudo from profils pr where pr.id = u;
  for p in select * from paliers_parties pp where pp.actif and pp.seuil <= n
             and not exists (select 1 from envois_paliers e where e.joueur = u and e.palier = pp.id) order by pp.seuil loop
    insert into envois_paliers (joueur, palier) values (u, p.id) on conflict do nothing;
    if found then
      insert into messages (joueur, titre, texte, cadeau)
      values (u, replace(replace(p.titre, '{pseudo}', pseudo), '{parties}', p.seuil::text),
                 replace(replace(p.texte, '{pseudo}', pseudo), '{parties}', p.seuil::text),
                 case when p.cadeau is null or p.cadeau = '{}'::jsonb then null else p.cadeau end);
      envoyes := envoyes + 1;
    end if;
  end loop;
  return envoyes;
end $$;

create or replace function public.declencher_paliers_parties() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.joueur is not null and new.mode in ('ia', 'enligne', '2v2') then perform envoyer_paliers_parties(new.joueur); end if;
  return new;
end $$;

create or replace function public.admin_paliers_parties() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'seuil', p.seuil, 'titre', p.titre, 'texte', p.texte, 'cadeau', p.cadeau, 'actif', p.actif,
            'envois', (select count(*) from envois_paliers e where e.palier = p.id),
            'eligibles', (select count(*) from (select joueur from parties_jouees where joueur is not null and mode in ('ia', 'enligne', '2v2')
                                                group by joueur having count(*) >= p.seuil) x)) order by p.seuil), '[]'::jsonb)
          from paliers_parties p);
end $$;

create or replace function public.admin_appliquer_paliers_parties() returns int
language plpgsql security definer set search_path = public as $$
declare u uuid; total int := 0;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  for u in select distinct joueur from parties_jouees where joueur is not null and mode in ('ia', 'enligne', '2v2') loop
    total := total + envoyer_paliers_parties(u);
  end loop;
  return total;
end $$;
