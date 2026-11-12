-- =====================================================================
-- RECYCLAGE DE TOUS LES EXEMPLAIRES EN TROP, en une seule fois
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-variantes.sql.
-- Mêmes règles que le recyclage carte par carte : seuls les exemplaires au-delà du maximum
-- utile d’un deck sont recyclés ; les cartes promotionnelles, de départ ou invoquées ne le sont jamais.
-- =====================================================================
create or replace function public.recycler_surplus() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); r record; total_ex int := 0; total_encre int := 0; cartes int := 0;
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  for r in select c.carte, c.nb, max_copies(c.carte) mx, k.rarete
           from collection c join catalogue k on k.carte = c.carte and not k.promo and k.achetable
           where c.joueur = u and c.nb > max_copies(c.carte) for update of c loop
    update collection set nb = r.mx where joueur = u and carte = r.carte;
    total_ex := total_ex + (r.nb - r.mx);
    total_encre := total_encre + (r.nb - r.mx) * coalesce((reglage('encre_recyclage') ->> r.rarete)::int, 0);
    cartes := cartes + 1;
  end loop;
  if total_encre > 0 then update profils set encre = encre + total_encre where id = u; end if;
  return jsonb_build_object('cartes', cartes, 'exemplaires', total_ex, 'encre', total_encre);
end $$;
grant execute on function public.recycler_surplus() to authenticated;
