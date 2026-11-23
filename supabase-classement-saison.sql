-- =====================================================================
-- CLASSEMENT PAR SAISON
-- À la fin de chaque saison (table « saisons ») :
--   1) les joueurs classés en 1 contre 1 qui ont joué au moins une partie classée jusqu’au bout
--      pendant la saison reçoivent une récompense en or, par message (boîte aux lettres) :
--      1er 200 or, 2e 100 or, 3e 50 or, 4e à 10e 25 or, 11e à 100e 10 or ;
--   2) toutes les cotes (1 contre 1 et 2 contre 2) repartent à 1200, et le classement repart à zéro.
-- La clôture se fait toute seule, à la première visite d’un joueur après la fin de la saison.
-- Les gains se changent dans le réglage « gains_classement » (voir tout en bas).
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-classement.sql,
-- supabase-saisons.sql et supabase-langues.sql. Il peut être relancé sans risque.
-- =====================================================================

-- Gains par rang : [rang maximum, or] ; le premier palier qui contient le rang s’applique
update public.economie set reglages = jsonb_build_object('gains_classement', '[[1,200],[2,100],[3,50],[10,25],[100,10]]'::jsonb) || reglages where id = 1;

create table if not exists public.classement_clotures (
  saison text primary key,
  cloture timestamptz not null default now(),
  recompenses int not null default 0
);
alter table public.classement_clotures enable row level security;

create table if not exists public.classement_palmares (
  saison text not null,
  joueur uuid not null references auth.users(id) on delete cascade,
  rang int not null, elo int not null, parties int not null, gain int not null default 0, heros text,
  primary key (saison, joueur)
);
alter table public.classement_palmares enable row level security;

-- Saisons déjà terminées avant l’installation : closes, sans récompense ni remise à zéro
insert into public.classement_clotures (saison, recompenses)
select id, 0 from public.saisons where (debut + duree_jours) <= current_date
on conflict do nothing;

create or replace function public.gain_classement(r int) returns int
language sql stable set search_path = public as $$
  select coalesce((select (p->>1)::int from jsonb_array_elements(coalesce(reglage('gains_classement'), '[[1,200],[2,100],[3,50],[10,25],[100,10]]'::jsonb)) p
                    where r <= (p->>0)::int order by (p->>0)::int limit 1), 0)
$$;

-- Dieu le plus joué en partie classée : panthéon ET palier de dévotion
-- (« gre-0 » Poséidon, « gre-1 » Zeus, « gre » Chaos…). En cas d’égalité, le plus récent l’emporte.
create or replace function public.heros_favori(u uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when coalesce(palier, 0) >= 2 then heros else heros || '-' || coalesce(palier, 0) end
  from parties_jouees
  where joueur = u and mode = 'enligne' and heros is not null
    and not (coalesce((details->>'abandon')::boolean, false) and enregistre_par is distinct from joueur)
  group by heros, case when coalesce(palier, 0) >= 2 then 2 else coalesce(palier, 0) end, palier
  order by count(*) desc, max(cree) desc limit 1
$$;
revoke execute on function public.heros_favori(uuid) from public, anon, authenticated;

-- Clôture des saisons terminées (appelée par le jeu ; ne fait rien s’il n’y a rien à clore)
create or replace function public.cloturer_classement() returns int
language plpgsql security definer set search_path = public as $$
declare s saisons; fin date; n int; total int := 0; x record; g int;
begin
  for s in select * from saisons where (debut + duree_jours) <= current_date
             and id not in (select saison from classement_clotures) order by debut loop
    perform pg_advisory_xact_lock(hashtext('cloture-classement-' || s.id));
    if exists (select 1 from classement_clotures where saison = s.id) then continue; end if;
    fin := s.debut + s.duree_jours;
    n := 0;
    for x in
      select p.id, p.pseudo, p.elo, p.elo_parties, row_number() over (order by p.elo desc, p.elo_parties desc, p.id) rang
        from profils p
       where p.elo_parties > 0
         and exists (select 1 from parties_jouees pj where pj.joueur = p.id and pj.mode = 'enligne'
                       and pj.cree >= s.debut::timestamptz and pj.cree < fin::timestamptz
                       and not (coalesce((pj.details->>'abandon')::boolean, false) and not pj.victoire))
       order by p.elo desc, p.elo_parties desc, p.id
    loop
      g := gain_classement(x.rang::int);
      insert into classement_palmares (saison, joueur, rang, elo, parties, gain, heros)
      values (s.id, x.id, x.rang, x.elo, x.elo_parties, g, heros_favori(x.id)) on conflict do nothing;
      if g > 0 then
        insert into messages (joueur, titre, texte, cadeau, titre_en, texte_en)
        values (x.id,
          format('Classement de la saison « %s » : %s', s.nom, case when x.rang = 1 then '1re place !' else x.rang || 'e place !' end),
          format('Bravo %s ! Vous terminez la saison « %s » à la %s place du classement, avec une cote de %s. Voici votre récompense : %s or. Les cotes repartent à 1200 pour la nouvelle saison : bonne chance !',
                 coalesce(x.pseudo, 'aventurier'), s.nom, case when x.rang = 1 then '1re' else x.rang || 'e' end, x.elo, g),
          jsonb_build_object('or', g),
          format('Season “%s” ranking: #%s!', s.nom, x.rang),
          format('Well done %s! You finish the “%s” season ranked #%s, with a rating of %s. Here is your reward: %s gold. Ratings go back to 1200 for the new season: good luck!',
                 coalesce(x.pseudo, 'adventurer'), s.nom, x.rang, x.elo, g));
        n := n + 1;
      end if;
    end loop;
    -- Nouvelle saison : tout le monde repart à 1200
    update profils set elo = 1200, elo_max = 1200, elo_parties = 0 where elo <> 1200 or elo_parties <> 0 or elo_max <> 1200;
    update profils set elo2v2 = 1200, elo2v2_max = 1200, elo2v2_parties = 0 where elo2v2 <> 1200 or elo2v2_parties <> 0 or elo2v2_max <> 1200;
    insert into classement_clotures (saison, recompenses) values (s.id, n);
    total := total + n;
  end loop;
  return total;
end $$;
grant execute on function public.cloturer_classement() to authenticated;

-- Classement : la saison en cours, ses récompenses, le podium de la saison passée, le héros favori de chacun
create or replace function public.classement(p_limite int default 100) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (
    select p.id, p.pseudo, p.titre, p.elo, p.elo_parties, p.elo_max,
           rank() over (order by p.elo desc) rang
    from profils p where p.elo_parties > 0),
  s as (select * from saison_en_cours()),
  der as (select saison from classement_clotures cc join saisons sa on sa.id = cc.saison where cc.recompenses > 0 order by sa.debut desc limit 1)
  select jsonb_build_object(
    'joueurs', (select coalesce(jsonb_agg(jsonb_build_object('rang', rang, 'pseudo', coalesce(pseudo, 'Joueur'), 'titre', titre, 'elo', elo,
        'parties', elo_parties, 'moi', id = auth.uid(), 'heros', case when rang <= 3 then heros_favori(id) end) order by rang, elo_parties desc), '[]'::jsonb)
        from (select * from c order by rang limit p_limite) x),
    'total', (select count(*) from c),
    'saison', (select jsonb_build_object('id', s.id, 'nom', s.nom, 'fin', (s.debut + s.duree_jours)) from s where s.id is not null),
    'gains', coalesce(reglage('gains_classement'), '[[1,200],[2,100],[3,50],[10,25],[100,10]]'::jsonb),
    'precedent', (select jsonb_build_object('saison', (select nom from saisons where id = der.saison),
        'podium', (select coalesce(jsonb_agg(jsonb_build_object('rang', pm.rang, 'pseudo', coalesce(pr.pseudo, 'Joueur'), 'elo', pm.elo, 'gain', pm.gain, 'heros', pm.heros) order by pm.rang), '[]'::jsonb)
                   from classement_palmares pm left join profils pr on pr.id = pm.joueur where pm.saison = der.saison and pm.rang <= 3)) from der),
    'moi', (select jsonb_build_object('elo', p.elo, 'parties', p.elo_parties, 'max', p.elo_max, 'rang', (select rang from c where c.id = p.id),
        'eligible', exists (select 1 from parties_jouees pj, s where pj.joueur = p.id and pj.mode = 'enligne' and s.id is not null
                              and pj.cree >= s.debut::timestamptz and not (coalesce((pj.details->>'abandon')::boolean, false) and not pj.victoire)))
      from profils p where p.id = auth.uid()))
$$;
grant execute on function public.classement(int) to authenticated;

-- Pour changer les gains plus tard (exemple) :
-- update public.economie set reglages = jsonb_set(reglages, '{gains_classement}', '[[1,300],[2,150],[3,75],[10,30],[100,10]]'::jsonb) where id = 1;
