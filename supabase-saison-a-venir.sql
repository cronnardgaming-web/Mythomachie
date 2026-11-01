-- =====================================================================
-- SAISON À VENIR : la page Saison se montre avant l’ouverture (travaux fermés, récompenses)
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-saisons.sql.
-- =====================================================================
create or replace function public.saison_a_venir() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s saisons; travaux jsonb := '[]'::jsonb; t jsonb; k int := 0; ouv date;
begin
  select * into s from saisons where active and debut > current_date order by debut limit 1;
  if s.id is null then return null; end if;
  for t in select x from jsonb_array_elements(s.travaux) x loop
    ouv := s.debut + coalesce((t->>'ouverture_jour')::int, (k/2)*7 + (k%2)*3);
    travaux := travaux || jsonb_build_object('nom', t->>'nom', 'description', t->>'description', 'numero', k + 1,
      'ouverture', ouv::timestamptz, 'ouvert', false, 'fini', false, 'quetes', '[]'::jsonb);
    k := k + 1;
  end loop;
  return jsonb_build_object('id', s.id, 'nom', s.nom, 'debut', s.debut, 'fin', (s.debut + s.duree_jours)::timestamptz, 'a_venir', true,
    'travaux', travaux, 'finis', 0, 'paliers', s.paliers, 'paliers_reclames', '[]'::jsonb);
end $$;
grant execute on function public.saison_a_venir() to authenticated;
