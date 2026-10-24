-- Modification manuelle de l'or et de l'encre d'un joueur (réservée à l'administrateur).
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-phase4.sql.
create or replace function public.admin_modifier_ressources(p_joueur uuid, p_or int, p_encre int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  if p_or is null or p_encre is null or p_or < 0 or p_encre < 0 or p_or > 10000000 or p_encre > 10000000 then
    raise exception 'Valeurs invalides : l’or et l’encre doivent être des nombres entiers positifs.';
  end if;
  update profils set pieces_or = p_or, encre = p_encre where id = p_joueur returning pieces_or, encre into r;
  if not found then raise exception 'Joueur introuvable.'; end if;
  return jsonb_build_object('or', r.pieces_or, 'encre', r.encre);
end $$;
grant execute on function public.admin_modifier_ressources(uuid, int, int) to authenticated;
