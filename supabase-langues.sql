-- =====================================================================
-- LANGUES : version anglaise des messages, des notes de mise à jour et des cadeaux automatiques
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-social.sql
-- et supabase-cadeaux-auto.sql. Il peut être relancé sans risque.
-- Les champs anglais sont facultatifs : vides, les joueurs anglophones voient le texte français.
-- =====================================================================
alter table public.messages        add column if not exists titre_en text not null default '';
alter table public.messages        add column if not exists texte_en text not null default '';
alter table public.notes_maj       add column if not exists titre_en text not null default '';
alter table public.notes_maj       add column if not exists texte_en text not null default '';
alter table public.paliers_parties add column if not exists titre_en text not null default '';
alter table public.paliers_parties add column if not exists texte_en text not null default '';

-- Boîte aux lettres : envoi d’un message, avec sa version anglaise
drop function if exists public.admin_envoyer_message(jsonb, text, text, jsonb);
drop function if exists public.admin_envoyer_message(jsonb, text, text, jsonb, text, text);
create or replace function public.admin_envoyer_message(p_dest jsonb, p_titre text, p_texte text, p_cadeau jsonb,
                                                        p_titre_en text default '', p_texte_en text default '') returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if coalesce(trim(p_titre), '') = '' then raise exception 'Le message doit avoir un titre.'; end if;
  insert into messages (joueur, titre, texte, cadeau, titre_en, texte_en)
  select p.id, left(trim(p_titre), 120), left(coalesce(p_texte, ''), 4000),
         case when p_cadeau is null or p_cadeau = '{}'::jsonb then null else p_cadeau end,
         left(trim(coalesce(p_titre_en, '')), 120), left(coalesce(p_texte_en, ''), 4000)
  from profils p join auth.users u on u.id = p.id
  where (p_dest is null and u.email is not null)
     or (jsonb_typeof(p_dest) = 'array' and p.id::text in (select jsonb_array_elements_text(p_dest)));
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.admin_envoyer_message(jsonb, text, text, jsonb, text, text) to authenticated;

-- Notes de mise à jour
create or replace function public.admin_maj_note(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare i bigint;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if (p->>'id') is null then
    insert into notes_maj (version, titre, texte, publie, titre_en, texte_en)
    values (coalesce(p->>'version', ''), coalesce(nullif(p->>'titre', ''), 'Mise à jour'), coalesce(p->>'texte', ''), coalesce((p->>'publie')::boolean, false),
            coalesce(p->>'titre_en', ''), coalesce(p->>'texte_en', '')) returning id into i;
  else
    update notes_maj set version = coalesce(p->>'version', ''), titre = coalesce(nullif(p->>'titre', ''), 'Mise à jour'), texte = coalesce(p->>'texte', ''),
      publie = coalesce((p->>'publie')::boolean, false), titre_en = coalesce(p->>'titre_en', ''), texte_en = coalesce(p->>'texte_en', '')
      where id = (p->>'id')::bigint returning id into i;
  end if;
  return i;
end $$;
grant execute on function public.admin_maj_note(jsonb) to authenticated;

-- Cadeaux automatiques : chaque message part avec sa version anglaise
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
      insert into messages (joueur, titre, texte, cadeau, titre_en, texte_en)
      values (u, replace(replace(p.titre, '{pseudo}', pseudo), '{parties}', p.seuil::text),
                 replace(replace(p.texte, '{pseudo}', pseudo), '{parties}', p.seuil::text),
                 case when p.cadeau is null or p.cadeau = '{}'::jsonb then null else p.cadeau end,
                 replace(replace(p.titre_en, '{pseudo}', pseudo), '{parties}', p.seuil::text),
                 replace(replace(p.texte_en, '{pseudo}', pseudo), '{parties}', p.seuil::text));
      envoyes := envoyes + 1;
    end if;
  end loop;
  return envoyes;
end $$;
revoke execute on function public.envoyer_paliers_parties(uuid) from public, anon, authenticated;

create or replace function public.admin_paliers_parties() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'seuil', p.seuil, 'titre', p.titre, 'texte', p.texte, 'titre_en', p.titre_en, 'texte_en', p.texte_en,
            'cadeau', p.cadeau, 'actif', p.actif,
            'envois', (select count(*) from envois_paliers e where e.palier = p.id),
            'eligibles', (select count(*) from (select joueur from parties_jouees where joueur is not null and mode in ('ia', 'enligne', '2v2')
                                                group by joueur having count(*) >= p.seuil) x)) order by p.seuil), '[]'::jsonb)
          from paliers_parties p);
end $$;
grant execute on function public.admin_paliers_parties() to authenticated;

create or replace function public.admin_maj_paliers_parties(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare x jsonb; garde bigint[] := '{}'; i bigint;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  for x in select v from jsonb_array_elements(coalesce(p, '[]'::jsonb)) v loop
    if coalesce((x->>'seuil')::int, 0) <= 0 or coalesce(trim(x->>'titre'), '') = '' then raise exception 'Chaque palier doit avoir un nombre de parties et un titre.'; end if;
    if (x->>'id') is not null and exists (select 1 from paliers_parties where id = (x->>'id')::bigint) then
      update paliers_parties set seuil = (x->>'seuil')::int, titre = left(x->>'titre', 120), texte = left(coalesce(x->>'texte', ''), 4000),
        titre_en = left(coalesce(x->>'titre_en', ''), 120), texte_en = left(coalesce(x->>'texte_en', ''), 4000),
        cadeau = nullif(x->'cadeau', '{}'::jsonb), actif = coalesce((x->>'actif')::boolean, true) where id = (x->>'id')::bigint returning id into i;
    else
      insert into paliers_parties (seuil, titre, texte, titre_en, texte_en, cadeau, actif)
      values ((x->>'seuil')::int, left(x->>'titre', 120), left(coalesce(x->>'texte', ''), 4000),
              left(coalesce(x->>'titre_en', ''), 120), left(coalesce(x->>'texte_en', ''), 4000),
              nullif(x->'cadeau', '{}'::jsonb), coalesce((x->>'actif')::boolean, true)) returning id into i;
    end if;
    garde := garde || i;
  end loop;
  delete from paliers_parties where not (id = any(garde));
  return cardinality(garde);
end $$;
grant execute on function public.admin_maj_paliers_parties(jsonb) to authenticated;
