-- =====================================================================
-- CORRECTIF 2 CONTRE 2 : les parties n’étaient pas comptées (ticket refusé par le serveur)
-- À exécuter une fois dans Supabase (SQL Editor, puis Run). Il peut être relancé sans risque.
-- La table des tickets n’acceptait que les modes « ia », « duo » et « enligne » : on y ajoute « 2v2 ».
-- =====================================================================
do $$
declare c text;
begin
  -- Supprime l’ancienne contrainte sur le mode, quel que soit son nom
  for c in select conname from pg_constraint
           where conrelid = 'public.tickets_partie'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%mode%' loop
    execute format('alter table public.tickets_partie drop constraint %I', c);
  end loop;
end $$;
alter table public.tickets_partie add constraint tickets_partie_mode_check check (mode in ('ia', 'duo', 'enligne', '2v2'));

-- Vérification : la contrainte doit maintenant inclure « 2v2 »
select pg_get_constraintdef(oid) as modes_autorises from pg_constraint
 where conrelid = 'public.tickets_partie'::regclass and conname = 'tickets_partie_mode_check';
