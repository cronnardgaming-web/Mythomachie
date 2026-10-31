-- =====================================================================
-- CORRECTIF : une quête du jour obtenue en remplacement ne compte que les parties jouées après le remplacement
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-recompenses.sql.
-- Les 3 quêtes du jour restent disponibles dès minuit ; les quêtes de saison comptaient déjà
-- uniquement les parties jouées depuis l’ouverture de leur travail.
-- =====================================================================
alter table public.quetes_jour add column if not exists depuis jsonb not null default '{}'::jsonb;

-- Instant à partir duquel une quête compte : son remplacement, sinon le début de la journée
create or replace function public.debut_quete(q quetes_jour, id text) returns timestamptz
language sql immutable as $$
  select coalesce((q.depuis->>id)::timestamptz, q.jour::timestamptz)
$$;

drop function if exists public.progres_quete(uuid, text);
create or replace function public.progres_quete(u uuid, cle text, depuis timestamptz) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(case
    when cle = 'parties' then count(*)
    when cle = 'victoires' then count(*) filter (where victoire)
    when cle like 'vic\_%' then count(*) filter (where victoire and heros = substr(cle, 5))
    when cle = 'creatures' then sum(creatures) when cle = 'sorts' then sum(sorts) when cle = 'achats' then sum(achats)
    when cle = 'degats' then sum(degats) when cle = 'soins' then sum(soins) when cle = 'pouvoirs' then sum(pouvoirs)
  end, 0)::int
  from parties_jouees where joueur = u and mode in ('ia', 'enligne') and cree::date = current_date and cree >= depuis
$$;
revoke execute on function public.progres_quete(uuid, text, timestamptz) from public, anon, authenticated;

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
    select coalesce(jsonb_agg(c || jsonb_build_object('progres', least(progres_quete(u, c->>'cle', debut_quete(q, c->>'id')), (c->>'but')::int), 'faite', q.reclamees ? (c->>'id')) order by i.ord), '[]'::jsonb)
    from jsonb_array_elements_text(q.ids) with ordinality i(id, ord) join jsonb_array_elements(cat) c on c->>'id' = i.id));
end $$;

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
  if progres_quete(u, c->>'cle', debut_quete(q, p_id)) < (c->>'but')::int then
    perform noter_alerte(u, 'quete_non_terminee', 'forte', jsonb_build_object('quete', c->>'texte', 'progres', progres_quete(u, c->>'cle', debut_quete(q, p_id)), 'objectif', c->'but'));
    return jsonb_build_object('erreur', 'Cette quête n’est pas encore terminée.');
  end if;
  update quetes_jour set reclamees = reclamees || to_jsonb(p_id) where joueur = u and jour = current_date;
  update profils set pieces_or = pieces_or + gain where id = u;
  return jsonb_build_object('gain', gain);
end $$;

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
  update quetes_jour set ids = (select jsonb_agg(case when e = p_id then nouvelle else e end order by o) from jsonb_array_elements_text(q.ids) with ordinality t(e, o)), remplacee = true,
    depuis = depuis || jsonb_build_object(nouvelle, now())
  where joueur = u and jour = current_date;
  return jsonb_build_object('ok', true);
end $$;
